import Foundation
import Testing
@testable import ConversionKit

/// Thread-safe recorder for the transcoder fake.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func record(_ v: T) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    var last: T? { values.last }
}

private struct StubTranscoder: TextureTranscoder {
    let handler: @Sendable (Data, TextureColorSpace) throws -> DecodedImage
    func transcode(_ ktx2: Data, usage: TextureColorSpace) throws -> DecodedImage { try handler(ktx2, usage) }
}

private func captureError(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); return nil } catch { return error }
}

@Suite struct KTX2TranscodeTests {

    private let options = ImportOptions()

    /// Minimal triangle GLB whose base-color (and optionally normal) texture is a
    /// `KHR_texture_basisu` KTX2 image supplied via a data URI, with an optional
    /// uncompressed fallback `texture.source`.
    private func ktx2GLB(
        ktx2Bytes: Data = Data([0x4B, 0x54, 0x58, 0x20]),
        slot: String = "baseColorTexture",
        fallbackURI: String? = nil,
        ktx2ViaBufferView: Bool = false
    ) -> Data {
        let ktx2URI = "data:image/ktx2;base64,\(ktx2Bytes.base64EncodedString())"
        let fallbackImage = fallbackURI.map { "{\"uri\":\"\($0)\",\"mimeType\":\"image/png\"}," } ?? ""
        // Image index 0 is the fallback (when present); the KTX2 image follows.
        let ktx2ImageIndex = fallbackURI == nil ? 0 : 1
        let fallbackSourceField = fallbackURI == nil ? "" : "\"source\":0,"

        let ktx2Image: String
        var extraBufferViews = ""
        var binExtra = Data()
        if ktx2ViaBufferView {
            // KTX2 bytes live in a bufferView after the geometry (offset 48).
            ktx2Image = "{\"mimeType\":\"image/ktx2\",\"bufferView\":2}"
            extraBufferViews = ",{\"buffer\":0,\"byteOffset\":48,\"byteLength\":\(ktx2Bytes.count)}"
            binExtra = ktx2Bytes
        } else {
            ktx2Image = "{\"mimeType\":\"image/ktx2\",\"uri\":\"\(ktx2URI)\"}"
        }

        let matSlot: String
        switch slot {
        case "normalTexture": matSlot = "\"normalTexture\":{\"index\":0}"
        case "emissiveTexture": matSlot = "\"emissiveTexture\":{\"index\":0}"
        case "occlusionTexture": matSlot = "\"occlusionTexture\":{\"index\":0}"
        case "metallicRoughnessTexture": matSlot = "\"pbrMetallicRoughness\":{\"metallicRoughnessTexture\":{\"index\":0}}"
        default: matSlot = "\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0}}"
        }

        let json = """
        {
          "asset":{"version":"2.0"},
          "extensionsUsed":["KHR_texture_basisu"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"name":"Tri","primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
          "materials":[{"name":"M",\(matSlot)}],
          "textures":[{\(fallbackSourceField)"extensions":{"KHR_texture_basisu":{"source":\(ktx2ImageIndex)}}}],
          "images":[\(fallbackImage)\(ktx2Image)],
          "accessors":[
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
          "bufferViews":[
            {"buffer":0,"byteOffset":0,"byteLength":36},
            {"buffer":0,"byteOffset":40,"byteLength":6}\(extraBufferViews)],
          "buffers":[{"byteLength":\(48 + binExtra.count)}]
        }
        """
        var bin = GLTFFixtures.floats([0, 0, 0, 1, 0, 0, 0, 1, 0])  // 36 bytes positions
        bin.append(Data([0, 0, 0, 0]))                              // pad to 40
        bin.append(GLTFFixtures.uint16s([0, 1, 2]))                 // 6 bytes indices
        bin.append(Data([0, 0]))                                    // pad to 48
        bin.append(binExtra)
        return GLTFFixtures.glb(json: json, bin: bin)
    }

    private func rgba2x2(_ colorSpace: TextureColorSpace) -> DecodedImage {
        DecodedImage(rgba: Data(repeating: 0x7F, count: 16), width: 2, height: 2, colorSpace: colorSpace)
    }

    @Test func transcodesBaseColorKTX2ToPNGWithSRGBUsage() async throws {
        let recorder = Box<(Data, TextureColorSpace)>()
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { data, usage in
                recorder.record((data, usage))
                return DecodedImage(rgba: Data(repeating: 0x7F, count: 16), width: 2, height: 2, colorSpace: usage)
            }))
        let url = try GLTFFixtures.write(ktx2GLB(), name: "ktx2-base.glb")

        let result = try await importer.importAsset(at: url, options: options)
        let material = try #require(result.scene.materials.first)
        let tex = try #require(material.baseColorTexture)
        #expect(tex.mimeType == "image/png")
        guard case .data(let png) = tex.source else {
            Issue.record("expected embedded PNG data"); return
        }
        // The re-encoded bytes decode back to a 2×2 image.
        let decoded = try RGBAImageCodec.decode(png)
        #expect(decoded.width == 2 && decoded.height == 2)
        // Base color is sRGB, and the transcoder saw the real KTX2 bytes.
        #expect(recorder.last?.1 == .sRGB)
        #expect(recorder.last?.0 == Data([0x4B, 0x54, 0x58, 0x20]))
        #expect(result.diagnostics.contains { $0.stage == "decode-compressed" && $0.message.contains("→ 2×2") })
    }

    @Test func passesLinearUsageForNormalMap() async throws {
        let recorder = Box<TextureColorSpace>()
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, usage in recorder.record(usage); return self.rgba2x2(usage) }))
        let url = try GLTFFixtures.write(ktx2GLB(slot: "normalTexture"), name: "ktx2-normal.glb")

        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.normalTexture?.mimeType == "image/png")
        #expect(recorder.last == .linear)
    }

    @Test func readsKTX2BytesFromBufferView() async throws {
        let recorder = Box<Data>()
        let ktx2 = Data([1, 2, 3, 4, 5, 6])
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { data, usage in recorder.record(data); return self.rgba2x2(usage) }))
        let url = try GLTFFixtures.write(ktx2GLB(ktx2Bytes: ktx2, ktx2ViaBufferView: true), name: "ktx2-view.glb")

        _ = try await importer.importAsset(at: url, options: options)
        #expect(recorder.last == ktx2)
    }

    @Test func fallsBackToUncompressedSourceWhenTranscodeFails() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, _ in throw DecompressionError.decodeFailed(extension: "KHR_texture_basisu", detail: "boom") }))
        let url = try GLTFFixtures.write(ktx2GLB(fallbackURI: "fallback.png"), name: "ktx2-fallback.glb")

        let result = try await importer.importAsset(at: url, options: options)
        let tex = try #require(result.scene.materials.first?.baseColorTexture)
        #expect(tex.source == .uri("fallback.png"))
        #expect(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("uncompressed fallback") })
    }

    @Test func dropsWithErrorWhenTranscodeFailsAndNoFallback() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, _ in throw DecompressionError.decodeFailed(extension: "KHR_texture_basisu", detail: "boom") }))
        let url = try GLTFFixtures.write(ktx2GLB(), name: "ktx2-nofallback.glb")

        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.baseColorTexture == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("no fallback") })
    }

    @Test func dropsWithErrorOnMalformedTranscoderOutput() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, _ in
                DecodedImage(rgba: Data(repeating: 0, count: 3), width: 2, height: 2, colorSpace: .sRGB)  // not 16 bytes
            }))
        let url = try GLTFFixtures.write(ktx2GLB(), name: "ktx2-malformed.glb")

        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.baseColorTexture == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("malformed") })
    }

    @Test func defaultImporterUsesFallbackWithWarningWhenNoTranscoder() async throws {
        let url = try GLTFFixtures.write(ktx2GLB(fallbackURI: "fallback.png"), name: "ktx2-default-fallback.glb")
        let result = try await GLTFImporter().importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.baseColorTexture?.source == .uri("fallback.png"))
        #expect(result.diagnostics.contains { $0.message.contains("transcode failed") })
    }

    @Test func transcodesMetallicRoughnessWithLinearUsage() async throws {
        let recorder = Box<TextureColorSpace>()
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, usage in recorder.record(usage); return self.rgba2x2(usage) }))
        let url = try GLTFFixtures.write(ktx2GLB(slot: "metallicRoughnessTexture"), name: "ktx2-mr.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.metallicRoughnessTexture?.mimeType == "image/png")
        #expect(recorder.last == .linear)
    }

    @Test func transcodesEmissiveWithSRGBUsage() async throws {
        let recorder = Box<TextureColorSpace>()
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: StubTranscoder { _, usage in recorder.record(usage); return self.rgba2x2(usage) }))
        let url = try GLTFFixtures.write(ktx2GLB(slot: "emissiveTexture"), name: "ktx2-emis.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.emissiveTexture?.mimeType == "image/png")
        #expect(recorder.last == .sRGB)
    }
}
