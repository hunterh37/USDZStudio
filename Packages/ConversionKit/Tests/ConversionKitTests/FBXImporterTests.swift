import Testing
import Foundation
@testable import ConversionKit

/// A fake FBX2glTF runner: either returns a pre-written glTF/GLB URL or throws.
private struct FakeRunner: FBX2glTFRunning {
    enum Behavior {
        case produce(URL)
        case fail(any Error)
    }
    let behavior: Behavior

    func convert(input: URL, outputDir: URL) async throws -> URL {
        switch behavior {
        case .produce(let url): return url
        case .fail(let error): throw error
        }
    }
}

@Suite("FBXImporter")
struct FBXImporterTests {

    /// Writes a self-contained single-triangle `.gltf` (data-URI buffer) to a
    /// temp file — the same fixture mechanism GLTFImporterTests uses.
    private func writeTriangleGLTF() throws -> URL {
        let bin = GLTFFixtures.triangleBIN()
        let uri = "data:application/octet-stream;base64,\(bin.base64EncodedString())"
        let json = GLTFFixtures.triangleJSON(bufferURI: uri)
        return try GLTFFixtures.write(Data(json.utf8), name: "converted.gltf")
    }

    @Test func importsConvertedGLTFAndMergesDiagnostics() async throws {
        let produced = try writeTriangleGLTF()
        let importer = FBXImporter(runner: FakeRunner(behavior: .produce(produced)))

        let result = try await importer.importAsset(
            at: URL(fileURLWithPath: "/models/character.fbx"), options: ImportOptions())

        #expect(result.scene.triangleCount == 1)
        // The conversion diagnostic is prepended ahead of any GLTF diagnostics.
        let first = try #require(result.diagnostics.first)
        #expect(first.stage == "fbx-convert")
        #expect(first.severity == .info)
        #expect(first.message.contains("character.fbx"))
        #expect(first.message.contains("converted.gltf"))
    }

    @Test func surfacesRunnerError() async throws {
        let importer = FBXImporter(runner: FakeRunner(
            behavior: .fail(FBXImporter.FBXImportError.binaryNotFound("/x/FBX2glTF"))))
        await #expect(throws: FBXImporter.FBXImportError.binaryNotFound("/x/FBX2glTF")) {
            _ = try await importer.importAsset(
                at: URL(fileURLWithPath: "/a.fbx"), options: ImportOptions())
        }
    }

    @Test func registersFBXInStandardRegistry() {
        let registry = ImporterRegistry.standard
        #expect(registry.registeredExtensions.contains("fbx"))
        #expect(registry.importer(for: URL(fileURLWithPath: "/x.fbx")) is FBXImporter)
    }

    @Test func errorMessagesAreDescriptive() {
        #expect(FBXImporter.FBXImportError.binaryNotFound("/p").message.contains("/p"))
        #expect(FBXImporter.FBXImportError.conversionFailed(stderr: "boom").message.contains("boom"))
        #expect(FBXImporter.FBXImportError.noOutputProduced.message.contains("no glTF"))
    }
}

@Suite("FBX2glTFRunner")
struct FBX2glTFRunnerTests {

    @Test func defaultInitResolvesABinaryPath() {
        let runner = FBX2glTFRunner()
        #expect(!runner.binaryPath.isEmpty)
        #expect(runner.binaryPath.hasSuffix(FBX2glTFRunner.defaultRelativePath)
            || runner.binaryPath == ProcessInfo.processInfo.environment["FBX2GLTF_PATH"])
    }

    @Test func missingBinaryThrowsBinaryNotFound() async throws {
        let runner = FBX2glTFRunner(binaryPath: "/nonexistent/FBX2glTF")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: FBXImporter.FBXImportError.binaryNotFound("/nonexistent/FBX2glTF")) {
            _ = try await runner.convert(
                input: URL(fileURLWithPath: "/a.fbx"), outputDir: out)
        }
    }

    @Test func noOutputProducedWhenBinaryEmitsNothing() async throws {
        // /bin/echo exits 0, writes no glb and no stderr → noOutputProduced.
        let runner = FBX2glTFRunner(binaryPath: "/bin/echo")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbx-noout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await #expect(throws: FBXImporter.FBXImportError.noOutputProduced) {
            _ = try await runner.convert(
                input: URL(fileURLWithPath: "/model.fbx"), outputDir: out)
        }
    }

    @Test func conversionFailedWhenBinaryWritesStderrButNoOutput() async throws {
        // A stub "binary" that writes to stderr, exits 0, produces no glb.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbx-stub-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'no fbx sdk' >&2\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let runner = FBX2glTFRunner(binaryPath: stub.path)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbx-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        await #expect(throws: FBXImporter.FBXImportError.conversionFailed(stderr: "no fbx sdk\n")) {
            _ = try await runner.convert(
                input: URL(fileURLWithPath: "/model.fbx"), outputDir: out)
        }
    }
}
