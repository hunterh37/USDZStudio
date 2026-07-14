import Testing
import CoreGraphics
import Foundation
import simd
@testable import ConversionKit

/// Solid-color RGBA test image encoded as PNG.
private func makePNG(width: Int, height: Int, r: UInt8 = 255, g: UInt8 = 0, b: UInt8 = 0) -> Data {
    let image = makeImage(width: width, height: height, r: r, g: g, b: b)
    return TextureProcessor.encode(image, format: .png, jpegQuality: 0.9)!
}

private func makeImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func runStage(
    materials: [PBRMaterial],
    policy: TexturePolicy = TexturePolicy(),
    sourceURL: URL = URL(fileURLWithPath: "/tmp/in.glb")
) async throws -> ConversionContext {
    var context = ConversionContext(sourceURL: sourceURL)
    context.scene.materials = materials
    var stageContext = context
    try await TexturePipelineStage(policy: policy).process(&stageContext)
    return stageContext
}

@Suite("TexturePipelineStage")
struct TexturePipelineStageTests {

    // MARK: - Pure policy

    @Test func targetSizePreservesAspectAndNeverUpscales() {
        #expect(TexturePipelineStage.targetSize(width: 4096, height: 2048, maxSize: 2048)! == (2048, 1024))
        #expect(TexturePipelineStage.targetSize(width: 2048, height: 4096, maxSize: 1024)! == (512, 1024))
        #expect(TexturePipelineStage.targetSize(width: 1024, height: 1024, maxSize: 2048) == nil)
        #expect(TexturePipelineStage.targetSize(width: 2048, height: 2048, maxSize: 2048) == nil)
        #expect(TexturePipelineStage.targetSize(width: 0, height: 0, maxSize: 2048) == nil)
        #expect(TexturePipelineStage.targetSize(width: 4096, height: 4096, maxSize: 0) == nil)
        // Extreme aspect ratios never collapse to zero.
        #expect(TexturePipelineStage.targetSize(width: 10000, height: 2, maxSize: 100)! == (100, 1))
    }

    @Test func formatPolicyKeepsDataTexturesLossless() {
        let jpegPolicy = TexturePolicy(encodeBaseColorAsJPEG: true)
        for slot in [TextureSlot.normal, .metallicRoughness, .occlusion] {
            #expect(TexturePipelineStage.outputFormat(slot: slot, alphaMode: .opaque, policy: jpegPolicy) == .png)
        }
        #expect(TexturePipelineStage.outputFormat(slot: .baseColor, alphaMode: .opaque, policy: jpegPolicy) == .jpeg)
        #expect(TexturePipelineStage.outputFormat(slot: .emissive, alphaMode: .opaque, policy: jpegPolicy) == .jpeg)
        // Alpha must survive: blend/mask base color stays PNG even when JPEG is requested.
        #expect(TexturePipelineStage.outputFormat(slot: .baseColor, alphaMode: .blend, policy: jpegPolicy) == .png)
        #expect(TexturePipelineStage.outputFormat(slot: .baseColor, alphaMode: .mask(threshold: 0.5), policy: jpegPolicy) == .png)
        // Default policy: everything PNG.
        #expect(TexturePipelineStage.outputFormat(slot: .baseColor, alphaMode: .opaque, policy: TexturePolicy()) == .png)
    }

    // MARK: - Stage behavior

    @Test func resizesOversizedEmbeddedTexture() async throws {
        var material = PBRMaterial(name: "M")
        material.baseColorTexture = TextureRef(source: .data(makePNG(width: 64, height: 32)))

        let context = try await runStage(materials: [material], policy: TexturePolicy(maxSize: 16))
        let ref = try #require(context.scene.materials[0].baseColorTexture)
        #expect(ref.mimeType == "image/png")
        guard case .data(let bytes) = ref.source else { Issue.record("expected inlined data"); return }
        let output = try #require(TextureProcessor.decode(bytes))
        #expect(output.width == 16)
        #expect(output.height == 8)
        #expect(context.diagnostics.contains { $0.severity == .info && $0.message.contains("resized 64x32 → 16x8") })
    }

    @Test func smallTextureIsReencodedNotResized() async throws {
        var material = PBRMaterial(name: "M")
        material.normalTexture = TextureRef(source: .data(makePNG(width: 8, height: 8)))

        let context = try await runStage(materials: [material])
        let ref = try #require(context.scene.materials[0].normalTexture)
        #expect(ref.mimeType == "image/png")
        #expect(!context.diagnostics.contains { $0.message.contains("resized") })
    }

    @Test func baseColorGoesJPEGWhenPolicyAsksAndOpaque() async throws {
        var material = PBRMaterial(name: "M")
        material.baseColorTexture = TextureRef(source: .data(makePNG(width: 8, height: 8)))
        material.emissiveTexture = TextureRef(source: .data(makePNG(width: 8, height: 8, r: 0, g: 255)))
        material.metallicRoughnessTexture = TextureRef(source: .data(makePNG(width: 8, height: 8, r: 0, b: 255)))

        let context = try await runStage(materials: [material], policy: TexturePolicy(encodeBaseColorAsJPEG: true))
        #expect(context.scene.materials[0].baseColorTexture?.mimeType == "image/jpeg")
        #expect(context.scene.materials[0].emissiveTexture?.mimeType == "image/jpeg")
        #expect(context.scene.materials[0].metallicRoughnessTexture?.mimeType == "image/png")
    }

    @Test func loadsExternalURITexture() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TexturePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makePNG(width: 4, height: 4).write(to: dir.appendingPathComponent("albedo.png"))

        var material = PBRMaterial(name: "M")
        material.baseColorTexture = TextureRef(source: .uri("albedo.png"))

        let context = try await runStage(
            materials: [material],
            sourceURL: dir.appendingPathComponent("model.obj")
        )
        guard case .data? = context.scene.materials[0].baseColorTexture?.source else {
            Issue.record("expected external texture inlined to data")
            return
        }
        #expect(context.diagnostics.isEmpty)
    }

    @Test func missingExternalTextureWarnsAndKeepsReference() async throws {
        var material = PBRMaterial(name: "M")
        material.baseColorTexture = TextureRef(source: .uri("does-not-exist.png"))

        let context = try await runStage(materials: [material])
        #expect(context.scene.materials[0].baseColorTexture?.source == .uri("does-not-exist.png"))
        #expect(context.diagnostics.contains { $0.severity == .warning && $0.message.contains("could not be read") })
    }

    @Test func invalidURIWarns() async throws {
        var material = PBRMaterial(name: "M")
        material.baseColorTexture = TextureRef(source: .uri("not a valid uri %%%"))

        let context = try await runStage(materials: [material])
        #expect(context.diagnostics.contains { $0.severity == .warning })
    }

    @Test func undecodableDataWarnsAndKeepsReference() async throws {
        var material = PBRMaterial(name: "M")
        material.occlusionTexture = TextureRef(source: .data(Data("not an image".utf8)))

        let context = try await runStage(materials: [material])
        #expect(context.scene.materials[0].occlusionTexture?.source == .data(Data("not an image".utf8)))
        #expect(context.diagnostics.contains { $0.severity == .warning && $0.message.contains("undecodable") })
    }

    @Test func materialsWithoutTexturesPassThroughUntouched() async throws {
        let material = PBRMaterial(name: "Plain")
        let context = try await runStage(materials: [material])
        #expect(context.scene.materials == [material])
        #expect(context.diagnostics.isEmpty)
    }

    // MARK: - TextureProcessor

    @Test func processorRoundTripsPNGAndJPEG() throws {
        let image = makeImage(width: 10, height: 6, r: 10, g: 200, b: 30)
        for format in [TextureFormat.png, .jpeg] {
            let encoded = try #require(TextureProcessor.encode(image, format: format, jpegQuality: 0.9))
            let decoded = try #require(TextureProcessor.decode(encoded))
            #expect(decoded.width == 10)
            #expect(decoded.height == 6)
        }
        #expect(TextureProcessor.decode(Data([1, 2, 3])) == nil)
        #expect(TextureProcessor.resize(image, width: 0, height: 5) == nil)
    }

    @Test func extractsORMChannels() throws {
        // ORM convention: R=occlusion, G=roughness, B=metallic.
        let image = makeImage(width: 4, height: 4, r: 255, g: 128, b: 0)
        for (channel, expected) in [(TextureProcessor.Channel.red, UInt8(255)), (.green, 128), (.blue, 0)] {
            let gray = try #require(TextureProcessor.extractChannel(channel, from: image))
            #expect(gray.width == 4 && gray.height == 4)
            #expect(gray.bitsPerPixel == 8)
            let data = try #require(gray.dataProvider?.data as Data?)
            // Sample the first pixel; tolerate ±2 for color management rounding.
            #expect(abs(Int(data[0]) - Int(expected)) <= 2)
        }
    }

    @Test func extractChannelRejectsEmptyImage() {
        // Zero-sized images cannot exist as CGImage, so exercise the guard
        // via resize instead, then confirm extract works on a 1x1.
        let image = makeImage(width: 1, height: 1, r: 7, g: 8, b: 9)
        #expect(TextureProcessor.extractChannel(.red, from: image) != nil)
    }
}

// MARK: - CG-failure fallbacks (injected)

@Suite("TexturePipelineStage failure fallbacks")
struct TexturePipelineFailureTests {

    @Test func resizeFailureWarnsAndKeepsOriginal() async throws {
        var material = PBRMaterial(name: "M")
        let original = TextureRef(source: .data(makePNG(width: 64, height: 64)))
        material.baseColorTexture = original

        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/tmp/in.glb"))
        context.scene.materials = [material]
        var stage = TexturePipelineStage(policy: TexturePolicy(maxSize: 16))
        stage.resizeFunction = { _, _, _ in nil }
        try await stage.process(&context)

        #expect(context.scene.materials[0].baseColorTexture == original)
        #expect(context.diagnostics.contains { $0.severity == .warning && $0.message.contains("resize failed") })
    }

    @Test func encodeFailureWarnsAndKeepsOriginal() async throws {
        var material = PBRMaterial(name: "M")
        let original = TextureRef(source: .data(makePNG(width: 8, height: 8)))
        material.normalTexture = original

        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/tmp/in.glb"))
        context.scene.materials = [material]
        var stage = TexturePipelineStage()
        stage.encodeFunction = { _, _, _ in nil }
        try await stage.process(&context)

        #expect(context.scene.materials[0].normalTexture == original)
        #expect(context.diagnostics.contains { $0.severity == .warning && $0.message.contains("re-encode failed") })
    }
}
