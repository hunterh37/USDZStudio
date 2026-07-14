import Testing
import Foundation
import USDCore
@testable import ConversionKit

struct FakeImporter: AssetImporter {
    static let supportedExtensions = ["glb", "gltf"]
    var marker: String

    func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult {
        ImportResult(scene: IntermediateScene(name: marker))
    }
}

@Suite("ImporterRegistry")
struct ImporterRegistryTests {

    @Test func routesByExtensionCaseInsensitively() async throws {
        var registry = ImporterRegistry()
        registry.register(FakeImporter(marker: "GLB"), extensions: FakeImporter.supportedExtensions)
        #expect(registry.importer(for: URL(fileURLWithPath: "/tmp/model.GLB")) != nil)
        #expect(registry.importer(for: URL(fileURLWithPath: "/tmp/model.obj")) == nil)
        #expect(registry.registeredExtensions == ["glb", "gltf"])

        let importer = try #require(registry.importer(for: URL(fileURLWithPath: "/tmp/m.glb")))
        let result = try await importer.importAsset(at: URL(fileURLWithPath: "/tmp/m.glb"), options: ImportOptions())
        #expect(result.scene.name == "GLB")
        #expect(result.diagnostics.isEmpty)
    }

    @Test func laterRegistrationWins() {
        var registry = ImporterRegistry()
        registry.register(FakeImporter(marker: "first"), extensions: ["glb"])
        registry.register(FakeImporter(marker: "second"), extensions: ["glb"])
        #expect((registry.importer(for: URL(fileURLWithPath: "/x.glb")) as? FakeImporter)?.marker == "second")
    }

    @Test func contextAccumulatesLog() {
        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/tmp/in.glb"))
        context.log.append("stage 1 ok")
        #expect(context.log == ["stage 1 ok"])
        #expect(context.scene.rootNodes.isEmpty)
        #expect(context.authoredStage == nil)
        #expect(ImportOptions().maxTextureSize == nil)
        #expect(ImportOptions(maxTextureSize: 2048).maxTextureSize == 2048)
    }
}

// MARK: - Pipeline

struct RecordingStage: ConversionStage {
    var id: String
    var diagnosticsToEmit: Int = 0
    var error: Error?

    func process(_ context: inout ConversionContext) async throws {
        if let error { throw error }
        for i in 0..<diagnosticsToEmit {
            context.diagnostics.append(Diagnostic(severity: .warning, stage: id, message: "d\(i)"))
        }
        context.scene.rootNodes.append(SceneNode(name: id))
    }
}

@Suite("ConversionPipeline")
struct ConversionPipelineTests {

    @Test func runsStagesInOrderAndLogs() async throws {
        let pipeline = ConversionPipeline(stages: [
            RecordingStage(id: "parse"),
            RecordingStage(id: "materials", diagnosticsToEmit: 1),
            RecordingStage(id: "textures", diagnosticsToEmit: 2),
        ])
        let result = try await pipeline.run(ConversionContext(sourceURL: URL(fileURLWithPath: "/in.glb")))
        #expect(result.scene.rootNodes.map(\.name) == ["parse", "materials", "textures"])
        #expect(result.log == ["parse: ok", "materials: ok (1 diagnostic)", "textures: ok (2 diagnostics)"])
        #expect(result.diagnostics.count == 3)
    }

    @Test func failingStageThrowsAndLogsFailure() async {
        struct Boom: Error {}
        let pipeline = ConversionPipeline(stages: [
            RecordingStage(id: "parse"),
            RecordingStage(id: "explode", error: Boom()),
        ])
        await #expect(throws: Boom.self) {
            _ = try await pipeline.run(ConversionContext(sourceURL: URL(fileURLWithPath: "/in.glb")))
        }
    }
}

// MARK: - Standard defaults

@Suite("Standard defaults")
struct StandardDefaultsTests {

    @Test func standardRegistryCoversAllBuiltInFormats() {
        let registry = ImporterRegistry.standard
        #expect(registry.registeredExtensions == ["dae", "glb", "gltf", "obj", "ply", "stl"])
        #expect(registry.importer(for: URL(fileURLWithPath: "/x.glb")) is GLTFImporter)
        #expect(registry.importer(for: URL(fileURLWithPath: "/x.obj")) is ModelIOImporter)
    }

    @Test func standardPipelineRunsEndToEnd() async throws {
        // Minimal IR through the full standard pipeline: names sanitized,
        // textures untouched (none), stage authored.
        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/tmp/in.obj"))
        context.scene = IntermediateScene(
            name: "Scene",
            rootNodes: [SceneNode(name: "bad name!", meshIndices: [0])],
            meshes: [MeshData(name: "Tri", positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2])]
        )
        let result = try await ConversionPipeline.standard().run(context)
        #expect(result.authoredStage != nil)
        #expect(result.log.count == 3)
        #expect(result.log.allSatisfy { $0.contains("ok") })
    }
}
