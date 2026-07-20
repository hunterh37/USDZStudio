import Testing
import Foundation
import USDCore
@testable import openusdz

/// An in-memory stand-in for the file system + bridge, so the whole round-trip
/// flow is exercised without Python. `saveTransform` models a lossy save: it is
/// handed the destination's base name so a test can make the plain save path and
/// the post-edit save path behave differently.
private final class FakeWorld: @unchecked Sendable {
    var files: [String: StageSnapshot] = [:]
    var textClean = true
    var openError: Error?
    var saveTransform: (String, StageSnapshot) -> StageSnapshot = { _, snapshot in snapshot }

    func environment() -> RoundTripCommand.Environment {
        RoundTripCommand.Environment(
            open: { [self] url in
                if let openError { throw openError }
                guard let snapshot = files[url.lastPathComponent] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return snapshot
            },
            save: { [self] snapshot, url in
                files[url.lastPathComponent] = saveTransform(url.lastPathComponent, snapshot)
            },
            textDiffClean: { [self] _, _ in textClean },
            temporaryDirectory: { URL(fileURLWithPath: "/tmp/fake-roundtrip") })
    }
}

private func stage(_ name: String = "Root", visibility: Visibility = .inherited) -> StageSnapshot {
    let child = Prim(path: PrimPath("/\(name)/Child")!, typeName: "Mesh")
    let root = Prim(path: PrimPath("/\(name)")!, typeName: "Xform",
                    visibility: visibility, children: [child])
    return StageSnapshot(metadata: StageMetadata(defaultPrim: name), rootPrims: [root])
}

@Suite("openusdz roundtrip")
struct RoundTripCommandTests {

    private func capture() -> (out: Box, err: Box) { (Box(), Box()) }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    @Test func cleanFilePassesBothInvariants() async {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model.usda"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 0)
        #expect(out.text.contains("PASS  model.usda"))
        #expect(out.text.contains("idempotent:      ok"))
    }

    @Test func lossySaveFailsIdempotence() async {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        // Simulate a save that drops the child prim.
        world.saveTransform = { _, snapshot in
            var copy = snapshot
            copy.rootPrims[0].children = []
            return copy
        }
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model.usda"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 1)
        #expect(out.text.contains("FAIL"))
        #expect(out.text.contains("prims lost: /Root/Child"))
    }

    @Test func editUndoDivergenceIsReported() async {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        // Only the post-edit save is lossy, so edit→undo-all→save diverges from
        // the plain save/reopen result.
        world.saveTransform = { name, snapshot in
            guard name.hasPrefix("edited") else { return snapshot }
            var copy = snapshot
            copy.metadata.defaultPrim = "Tampered"
            return copy
        }
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model.usda"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 1)
        #expect(out.text.contains("edit→undo-all did not restore the opened model"))
    }

    @Test func strictFlagReportsTextDiff() async {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        world.textClean = false
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model.usda", "--strict"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 1)
        #expect(out.text.contains("flattened text diff clean:      FAILED"))

        world.textClean = true
        let (out2, err2) = capture()
        let code2 = await RoundTripCommand.run(
            arguments: ["model.usda", "--strict"], environment: world.environment(),
            print: out2.append, printError: err2.append)
        #expect(code2 == 0)
        #expect(out2.text.contains("flattened text diff clean:      ok"))
    }

    @Test func jsonOutputCarriesEveryInvariant() async throws {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model.usda", "--strict", "--json"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 0)
        let object = try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any]
        let payload = try #require(object)
        #expect(payload["passed"] as? Bool == true)
        let reports = try #require(payload["reports"] as? [[String: Any]])
        #expect(reports.count == 1)
        #expect(reports[0]["idempotent"] as? Bool == true)
        #expect(reports[0]["editUndoNeutral"] as? Bool == true)
        #expect(reports[0]["strictTextClean"] as? Bool == true)
    }

    @Test func jsonOmitsStrictWhenNotRequested() async throws {
        let world = FakeWorld()
        world.files["model.usda"] = stage()
        let (out, err) = capture()
        _ = await RoundTripCommand.run(
            arguments: ["model.usda", "--json"], environment: world.environment(),
            print: out.append, printError: err.append)
        let payload = try #require(try JSONSerialization.jsonObject(
            with: Data(out.text.utf8)) as? [String: Any])
        let reports = try #require(payload["reports"] as? [[String: Any]])
        #expect(reports[0]["strictTextClean"] == nil)
    }

    @Test func multipleFilesAreAllChecked() async {
        let world = FakeWorld()
        world.files["a.usda"] = stage("A")
        world.files["b.usda"] = stage("B")
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["a.usda", "b.usda"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 0)
        #expect(out.text.contains("a.usda"))
        #expect(out.text.contains("b.usda"))
    }

    @Test func openFailureExitsOne() async {
        let world = FakeWorld()
        world.openError = CocoaError(.fileReadCorruptFile)
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["broken.usda"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 1)
        #expect(err.text.contains("error: broken.usda"))
    }

    @Test func missingFileArgumentIsUsageError() async {
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: [], environment: FakeWorld().environment(),
            print: out.append, printError: err.append)
        #expect(code == 2)
        #expect(err.text.contains("needs at least one file"))
    }

    @Test func unknownOptionIsUsageError() async {
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["--nope", "x.usda"], environment: FakeWorld().environment(),
            print: out.append, printError: err.append)
        #expect(code == 2)
        #expect(err.text.contains("unknown option --nope"))
    }

    @Test func extensionlessPathStillRoundTrips() async {
        let world = FakeWorld()
        world.files["model"] = stage()
        let (out, err) = capture()
        let code = await RoundTripCommand.run(
            arguments: ["model"], environment: world.environment(),
            print: out.append, printError: err.append)
        #expect(code == 0)
    }
}

@Suite("roundtrip diagnostics")
struct RoundTripDiagnosticsTests {

    @Test func emptyStageProducesNoCommands() {
        #expect(RoundTripCommand.exerciseCommands(for: StageSnapshot()).isEmpty)
    }

    @Test func commandsToggleVisibilityBackFromInvisible() {
        let commands = RoundTripCommand.exerciseCommands(for: stage(visibility: .invisible))
        #expect(commands.count == 2)
        #expect(commands[0].label.hasPrefix("Show"))
    }

    @Test func describesMetadataDifference() {
        var other = stage()
        other.metadata.defaultPrim = "Other"
        #expect(RoundTripCommand.describe(difference: stage(), other).contains("stage metadata differs"))
    }

    @Test func describesGainedPrims() {
        var other = stage()
        other.rootPrims[0].children.append(Prim(path: PrimPath("/Root/Extra")!, typeName: "Mesh"))
        #expect(RoundTripCommand.describe(difference: stage(), other).contains("prims gained: /Root/Extra"))
    }

    @Test func describesReorderedPrims() {
        var other = stage()
        other.rootPrims[0].children.append(Prim(path: PrimPath("/Root/Second")!, typeName: "Mesh"))
        var reordered = other
        reordered.rootPrims[0].children.reverse()
        #expect(RoundTripCommand.describe(difference: other, reordered).contains("prim order differs"))
    }

    @Test func describesChangedPrimAtSamePath() {
        var other = stage()
        other.rootPrims[0].children[0].typeName = "Sphere"
        #expect(RoundTripCommand.describe(difference: stage(), other).contains("prim /Root/Child differs"))
    }

    @Test func identicalSnapshotsFallBackToGenericMessage() {
        #expect(RoundTripCommand.describe(difference: stage(), stage()) == "snapshots differ")
    }

    @Test func encodeJSONSurvivesEmptyInput() {
        #expect(RoundTripCommand.encodeJSON([]).contains("\"passed\" : true"))
    }
}
