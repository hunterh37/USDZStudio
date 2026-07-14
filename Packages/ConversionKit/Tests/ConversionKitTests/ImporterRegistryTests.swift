import Testing
import Foundation
import USDCore
@testable import ConversionKit

struct FakeImporter: AssetImporter {
    static let supportedExtensions = ["glb", "gltf"]
    var marker: String

    func importAsset(at url: URL, options: ImportOptions) async throws -> StageSnapshot {
        StageSnapshot(rootPrims: [Prim(path: PrimPath("/\(marker)")!)])
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
        let stage = try await importer.importAsset(at: URL(fileURLWithPath: "/tmp/m.glb"), options: ImportOptions())
        #expect(stage.rootPrims.first?.name == "GLB")
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
        #expect(context.stage.rootPrims.isEmpty)
        #expect(ImportOptions().maxTextureSize == nil)
        #expect(ImportOptions(maxTextureSize: 2048).maxTextureSize == 2048)
    }
}
