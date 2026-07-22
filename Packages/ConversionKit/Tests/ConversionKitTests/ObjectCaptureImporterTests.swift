import Testing
import Foundation
import CaptureKit
@testable import ConversionKit

/// A fake reconstruction seam: yields a scripted sequence of progress events
/// (and optionally an error), standing in for the hardware `PhotogrammetrySession`.
private struct FakeRunner: PhotogrammetryRunning {
    var events: [CaptureProgress]
    var error: Error?

    func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

private struct FakeError: Error, Equatable {}

private func urls(_ n: Int) -> [URL] {
    (0..<n).map { URL(fileURLWithPath: "/tmp/cap/img_\(String(format: "%03d", $0)).heic") }
}

/// A scene the injected reader hands back, standing in for the ModelIO decode.
private func fixtureResult() -> ImportResult {
    let scene = IntermediateScene(
        name: "Captured",
        rootNodes: [SceneNode(name: "Object")],
        meshes: [MeshData(name: "Object", positions: [SIMD3(0, 0, 0)], indices: [0, 0, 0])])
    return ImportResult(scene: scene, diagnostics: [
        Diagnostic(severity: .info, stage: "modelio-import", message: "read fixture")
    ])
}

private func makeImporter(
    images: [URL],
    events: [CaptureProgress],
    error: Error? = nil,
    detail: CaptureDetail = .medium,
    profile: CaptureProfile = .arkit,
    targetMetersPerUnit: Double? = nil
) -> ObjectCaptureImporter {
    ObjectCaptureImporter(
        runner: FakeRunner(events: events, error: error),
        detail: detail, profile: profile, targetMetersPerUnit: targetMetersPerUnit,
        listImages: { _ in images },
        readScene: { _, _ in fixtureResult() })
}

@Suite("ObjectCaptureImporter")
struct ObjectCaptureImporterTests {
    let anyURL = URL(fileURLWithPath: "/tmp/cap")

    @Test func supportedExtensions() {
        #expect(ObjectCaptureImporter.supportedExtensions == ["capture"])
    }

    @Test func happyPathReturnsSceneWithCaptureDiagnostics() async throws {
        let out = URL(fileURLWithPath: "/tmp/out/model.usdz")
        let importer = makeImporter(
            images: urls(30), events: [.progress(0.5), .modelReady(url: out)],
            detail: .medium, targetMetersPerUnit: 1.0)
        let result = try await importer.importAsset(at: anyURL, options: ImportOptions())

        #expect(result.scene.name == "Captured")
        // Reader diagnostic first, then capture diagnostics appended.
        #expect(result.diagnostics.first?.stage == "modelio-import")
        let messages = result.diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("overlapping angles") })      // advisory
        #expect(messages.contains { $0.contains("diffuse + normal") })         // diffuse-only caveat
        #expect(messages.contains { $0.contains("meters per unit") })          // scale note
    }

    @Test func fullDetailAmpleCaptureHasNoAdvisoryOrCaveat() async throws {
        let out = URL(fileURLWithPath: "/tmp/out/model.usdz")
        let importer = makeImporter(
            images: urls(60), events: [.modelReady(url: out)], detail: .full)
        let result = try await importer.importAsset(at: anyURL, options: ImportOptions())
        // Only the reader's own diagnostic — no capture advisories/caveats/scale note.
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].stage == "modelio-import")
    }

    @Test func rejectsBlockingPreflightBeforeSession() async {
        let importer = makeImporter(images: urls(5), events: [.modelReady(url: anyURL)])
        await #expect(throws: CaptureImportError.self) {
            _ = try await importer.importAsset(at: anyURL, options: ImportOptions())
        }
        do {
            _ = try await importer.importAsset(at: anyURL, options: ImportOptions())
        } catch let CaptureImportError.rejected(messages) {
            #expect(messages.contains { $0.contains("at least 20") })
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }
    }

    @Test func noImagesThrows() async {
        let importer = makeImporter(images: [], events: [])
        do {
            _ = try await importer.importAsset(at: anyURL, options: ImportOptions())
            Issue.record("expected throw")
        } catch let CaptureImportError.noImages(location) {
            #expect(location == anyURL.path)
        } catch {
            Issue.record("expected .noImages, got \(error)")
        }
    }

    @Test func sessionWithoutModelThrows() async {
        let importer = makeImporter(images: urls(60), events: [.progress(0.9)])
        await #expect(throws: CaptureImportError.sessionProducedNoModel) {
            _ = try await importer.importAsset(at: anyURL, options: ImportOptions())
        }
    }

    @Test func runnerErrorPropagates() async {
        let importer = makeImporter(images: urls(60), events: [.progress(0.1)], error: FakeError())
        await #expect(throws: FakeError.self) {
            _ = try await importer.importAsset(at: anyURL, options: ImportOptions())
        }
    }
}

@Suite("Capture value types")
struct CaptureValueTypeTests {
    @Test func progressEquatable() {
        #expect(CaptureProgress.progress(0.5) == .progress(0.5))
        #expect(CaptureProgress.progress(0.5) != .progress(0.6))
        let u = URL(fileURLWithPath: "/m.usdz")
        #expect(CaptureProgress.modelReady(url: u) == .modelReady(url: u))
        #expect(CaptureProgress.modelReady(url: u) != .progress(1))
    }

    @Test func errorRecoverySuggestions() {
        #expect(CaptureImportError.rejected(messages: []).recoverySuggestion.contains("blocking"))
        #expect(CaptureImportError.noImages(location: "/x").recoverySuggestion.contains("HEIC"))
        #expect(CaptureImportError.sessionProducedNoModel.recoverySuggestion.contains("no geometry"))
    }
}

@Suite("ObjectCaptureImporter.defaultListImages")
struct DefaultListImagesTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func gathersSupportedImagesSortedFromDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.heic", "a.jpg", "notes.txt", "c.PNG"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let found = ObjectCaptureImporter.defaultListImages(dir).map(\.lastPathComponent)
        #expect(found == ["a.jpg", "b.heic", "c.PNG"])  // sorted, .txt excluded
    }

    @Test func resolvesParentDirectoryForCaptureManifestFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("shot.heic"))
        let manifest = dir.appendingPathComponent("scan.capture")
        try Data("x".utf8).write(to: manifest)
        let found = ObjectCaptureImporter.defaultListImages(manifest).map(\.lastPathComponent)
        #expect(found == ["shot.heic"])  // manifest's own extension isn't an image
    }

    @Test func nonexistentPathYieldsNothing() {
        let missing = URL(fileURLWithPath: "/no/such/place-\(UUID().uuidString)")
        #expect(ObjectCaptureImporter.defaultListImages(missing).isEmpty)
    }
}
