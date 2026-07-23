import Foundation
import simd
import Testing
@testable import ConversionKit

private let options = ImportOptions()

private func captureError(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); return nil } catch { return error }
}

private struct AnyGeometryDecompressor: GeometryDecompressor {
    let handler: @Sendable (CompressedPrimitive) throws -> DecodedGeometry
    func decode(_ p: CompressedPrimitive) throws -> DecodedGeometry { try handler(p) }
}

private struct AnyTranscoder: TextureTranscoder {
    let handler: @Sendable (Data, TextureColorSpace) throws -> DecodedImage
    func transcode(_ d: Data, usage: TextureColorSpace) throws -> DecodedImage { try handler(d, usage) }
}

/// Edge branches around the compression paths that the happy-path suites don't
/// exercise — kept together so the ConversionKit 100% floor stays honest.
@Suite struct DecompressionEdgeCoverageTests {

    // MARK: Draco stream resolution errors

    private func dracoGLB(bufferView: Int, viewByteLength: Int, bufferByteLength: Int) -> Data {
        let json = """
        {
          "asset":{"version":"2.0"},"extensionsUsed":["KHR_draco_mesh_compression"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"name":"D","primitives":[{"attributes":{"POSITION":0},
            "extensions":{"KHR_draco_mesh_compression":{"bufferView":\(bufferView),"attributes":{"POSITION":0}}}}]}],
          "accessors":[{"componentType":5126,"count":3,"type":"VEC3"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":\(viewByteLength)}],
          "buffers":[{"byteLength":\(bufferByteLength)}]
        }
        """
        return GLTFFixtures.glb(json: json, bin: Data(repeating: 1, count: bufferByteLength))
    }

    @Test func dracoBufferViewIndexOutOfRange() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: AnyGeometryDecompressor { _ in DecodedGeometry(positions: [], indices: []) }))
        let url = try GLTFFixtures.write(dracoGLB(bufferView: 9, viewByteLength: 8, bufferByteLength: 8), name: "draco-badview.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        #expect(error as? GLTFImporter.GLTFError == .indexOutOfRange(what: "bufferView", index: 9))
    }

    @Test func dracoStreamExceedsBuffer() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: AnyGeometryDecompressor { _ in DecodedGeometry(positions: [], indices: []) }))
        // View claims 100 bytes of an 8-byte buffer.
        let url = try GLTFFixtures.write(dracoGLB(bufferView: 0, viewByteLength: 100, bufferByteLength: 8), name: "draco-streamoob.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        #expect(error as? GLTFImporter.GLTFError == .bufferOutOfBounds(buffer: 0))
    }

    // MARK: Bad JOINTS accessor (non-draco path)

    @Test func rejectsJointsAccessorWithUnsupportedComponentType() async throws {
        // JOINTS_0 must be ubyte(5121) or ushort(5123); a float accessor is invalid.
        let json = """
        {
          "asset":{"version":"2.0"},"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1}}]}],
          "accessors":[
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"componentType":5126,"count":3,"type":"VEC4"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
          "buffers":[{"byteLength":36}]
        }
        """
        let url = try GLTFFixtures.write(
            GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats([0, 0, 0, 1, 0, 0, 0, 1, 0])), name: "badjoints.glb")
        let error = await captureError { _ = try await GLTFImporter().importAsset(at: url, options: options) }
        guard case .unsupportedAccessor(let detail)? = error as? GLTFImporter.GLTFError else {
            Issue.record("expected unsupportedAccessor, got \(String(describing: error))"); return
        }
        #expect(detail.contains("joints accessor"))
    }

    // MARK: KTX2 image-resolution edges

    /// KTX2 texture whose basisu `source` and image are configurable, with no
    /// fallback source, so an unresolved KTX2 drops with a loud error.
    private func ktx2GLB(basisuSource: Int, imageJSON: String) -> Data {
        let json = """
        {
          "asset":{"version":"2.0"},"extensionsUsed":["KHR_texture_basisu"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
          "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
          "textures":[{"extensions":{"KHR_texture_basisu":{"source":\(basisuSource)}}}],
          "images":[\(imageJSON)],
          "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
          "buffers":[{"byteLength":36}]
        }
        """
        return GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats([0, 0, 0, 1, 0, 0, 0, 1, 0]))
    }

    @Test func ktx2SourceImageIndexOutOfRangeDropsLoudly() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: AnyTranscoder { _, usage in DecodedImage(rgba: Data(repeating: 0, count: 16), width: 2, height: 2, colorSpace: usage) }))
        // basisu.source points at image 99, which doesn't exist.
        let url = try GLTFFixtures.write(
            ktx2GLB(basisuSource: 99, imageJSON: "{\"mimeType\":\"image/ktx2\",\"uri\":\"x.ktx2\"}"), name: "ktx2-badsource.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.baseColorTexture == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("no fallback") })
    }

    @Test func ktx2ImageWithMissingExternalFileDropsLoudly() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            texture: AnyTranscoder { _, usage in DecodedImage(rgba: Data(repeating: 0, count: 16), width: 2, height: 2, colorSpace: usage) }))
        // Non-data URI pointing at a file that isn't there → imageBytes yields nil.
        let url = try GLTFFixtures.write(
            ktx2GLB(basisuSource: 0, imageJSON: "{\"mimeType\":\"image/ktx2\",\"uri\":\"missing-texture.ktx2\"}"), name: "ktx2-missingfile.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.first?.baseColorTexture == nil)
        #expect(result.diagnostics.contains { $0.severity == .error })
    }
}
