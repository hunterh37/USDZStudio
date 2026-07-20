import Testing
import Foundation
import USDCore
@testable import USDBridge

/// Integration tests that drive the *real* embedded Python + usd-core against
/// the committed bridge mini-corpus (`Fixtures/Corpus`) and exercise the
/// `StageSaver` save path end-to-end (author → save → reopen → assert).
///
/// These skip cleanly when no interpreter with `pxr` is importable (local dev
/// without the runtime); CI fetches usd-core first, so they always run there —
/// which is what lets USDBridge's coverage ratchet climb toward its 95% floor.
struct RealCorpus {

    /// Repo root, found by walking up from this source file until the bundled
    /// Python scripts are visible. Keeps tests independent of the CWD.
    static let repoRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Resources/Python/stage_snapshot.py").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate repo root from \(#filePath)")
    }()

    static var snapshotScript: String {
        repoRoot.appendingPathComponent("Resources/Python/stage_snapshot.py").path
    }
    static var corpusDir: URL {
        repoRoot.appendingPathComponent(
            "Packages/USDBridge/Tests/USDBridgeTests/Fixtures/Corpus", isDirectory: true)
    }

    /// A real process executor, or `nil` when usd-core isn't importable.
    ///
    /// The interpreter is resolved the same way the app resolves it, but with
    /// the repo's fetched runtime as the bundled root: `scripts/fetch-python-
    /// runtime.sh` installs usd-core into `Resources/Python/runtime`, *not* into
    /// the system `python3`. Looking only at `python3` is why these tests once
    /// passed locally (where the system interpreter happens to have `pxr`) while
    /// silently skipping in CI — which let USDBridge's real save-path coverage
    /// quietly fall through the gate.
    static func executor() async -> ProcessBridgeExecutor? {
        let locator = PythonRuntimeLocator(
            environment: ProcessInfo.processInfo.environment,
            bundledRuntimeRoot: repoRoot.appendingPathComponent("Resources/Python/runtime").path)
        guard let exec = ProcessBridgeExecutor(locator: locator, scriptPath: snapshotScript) else {
            return nil
        }
        if case .available = await exec.checkAvailability() { return exec }
        return nil
    }

    /// CI sets `USDBRIDGE_REQUIRE_USD=1`: there, a missing interpreter must fail
    /// loudly instead of skipping. A suite that silently no-ops when its
    /// dependency is absent reports green while testing nothing.
    static var requireUSD: Bool {
        ProcessInfo.processInfo.environment["USDBRIDGE_REQUIRE_USD"] == "1"
    }

    /// Returns an executor, or records a failure (CI) / signals a skip (local).
    static func executorOrSkip(_ function: String = #function) async -> ProcessBridgeExecutor? {
        if let exec = await executor() { return exec }
        if requireUSD {
            Issue.record("""
                \(function): usd-core is required here but no interpreter with `pxr` was found. \
                Run scripts/fetch-python-runtime.sh, or unset USDBRIDGE_REQUIRE_USD to skip.
                """)
        }
        return nil
    }

    static func fixture(_ name: String) -> URL { corpusDir.appendingPathComponent(name) }
}

@Suite("Bridge mini-corpus (real usd-core)")
struct BridgeCorpusTests {

    @Test func cubeOpensWithMeshChild() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        for ext in ["usda", "usdz"] {
            let stage = try await BridgedStage.open(url: RealCorpus.fixture("cube.\(ext)"), executor: exec)
            #expect(stage.prim(at: PrimPath("/Cube")!)?.typeName == "Xform")
            #expect(stage.prim(at: PrimPath("/Cube/Geom")!)?.typeName == "Mesh")
        }
    }

    @Test func variantsExposeVariantSet() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        let stage = try await BridgedStage.open(url: RealCorpus.fixture("variants.usda"), executor: exec)
        let widget = try #require(stage.prim(at: PrimPath("/Widget")!))
        let set = try #require(widget.variantSets.first)
        #expect(set.name == "color")
        #expect(Set(set.variants) == ["red", "blue"])
        #expect(set.selection == "red")
    }

    @Test func skeletonCarriesJoints() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        for ext in ["usda", "usdz"] {
            let stage = try await BridgedStage.open(url: RealCorpus.fixture("skel.\(ext)"), executor: exec)
            #expect(stage.prim(at: PrimPath("/Character")!)?.typeName == "SkelRoot")
            let skel = try #require(stage.prim(at: PrimPath("/Character/Skel")!))
            let joints = try #require(skel.attribute(named: "joints"))
            if case let .stringArray(values) = joints.value {
                #expect(values == ["Root", "Root/Bone"])
            } else if case let .tokenArray(values) = joints.value {
                #expect(values == ["Root", "Root/Bone"])
            } else {
                Issue.record("joints not an array of tokens: \(joints.value)")
            }
        }
    }

    /// Golden assertion pinning today's contract for animated stages.
    ///
    /// `stage_snapshot.py` reads attribute values at the *default* time only, so
    /// a purely time-sampled attribute has no default value and is surfaced as
    /// `.unsupported(typeName:)` — **preserved by name, never silently dropped**
    /// (PRD §4.2). Structure and prim tree survive intact.
    ///
    /// This is a known bridge gap, not a bug in the corpus: reading time samples
    /// across the wire is animation-phase work. If the bridge later learns to
    /// emit `timeSamples`, this test should flip to asserting `isAnimated` —
    /// which is exactly the regression signal the corpus exists to give.
    @Test func animatedStagePreservesTimeSampledAttributes() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        let stage = try await BridgedStage.open(url: RealCorpus.fixture("animated.usda"), executor: exec)
        #expect(stage.prim(at: PrimPath("/Mover")!)?.typeName == "Xform")
        #expect(stage.prim(at: PrimPath("/Mover/Ball")!)?.typeName == "Sphere")

        let mover = try #require(stage.prim(at: PrimPath("/Mover")!))
        let translate = try #require(mover.attribute(named: "xformOp:translate"))
        #expect(translate.value == .unsupported(typeName: "unsupported:double3"))
        #expect(translate.value.isEditable == false)
    }

    /// Same contract on the UsdSkel side: the SkelAnimation prim ships with its
    /// time-sampled channels preserved, and the *uniform* `joints` token array
    /// (which does have a default value) decodes properly.
    @Test func skelAnimationPrimPreservesChannels() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        let stage = try await BridgedStage.open(url: RealCorpus.fixture("skel.usda"), executor: exec)
        let anim = try #require(stage.prim(at: PrimPath("/Character/Anim")!))
        #expect(anim.typeName == "SkelAnimation")
        for channel in ["translations", "rotations", "scales"] {
            #expect(anim.attribute(named: channel) != nil, "\(channel) must survive the bridge")
        }
        #expect(anim.attribute(named: "joints")?.value == .stringArray(["Root", "Root/Bone"]))
    }

    @Test func malformedFileSurfacesAnError() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        await #expect(throws: BridgeError.self) {
            _ = try await BridgedStage.open(url: RealCorpus.fixture("malformed.usda"), executor: exec)
        }
    }
}

@Suite("StageSaver round-trip (real usd-core)")
struct StageSaverRoundTripTests {

    /// A small authored stage: /Root/Child (Mesh) with one attribute.
    private func authoredStage() -> StageSnapshot {
        let child = Prim(path: PrimPath("/Root/Child")!, typeName: "Mesh",
                         attributes: [Attribute(name: "radius", value: .double(2.5))])
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [child])
        return StageSnapshot(metadata: StageMetadata(defaultPrim: "Root"), rootPrims: [root])
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(arguments: ["usda", "usdc", "usdz"])
    func authorSaveReopenPreservesStructure(_ ext: String) async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("model.\(ext)")

        try await StageSaver.save(authoredStage(), to: out, executor: exec)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let reopened = try await BridgedStage.open(url: out, executor: exec)
        #expect(reopened.prim(at: PrimPath("/Root")!)?.typeName == "Xform")
        #expect(reopened.prim(at: PrimPath("/Root/Child")!)?.typeName == "Mesh")
    }

    @Test func overwritingExistingUsdzReplacesInPlace() async throws {
        guard let exec = await RealCorpus.executorOrSkip() else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("model.usdz")

        // First save creates it; second save must hit the replace-in-place path.
        try await StageSaver.save(authoredStage(), to: out, executor: exec)
        let firstSize = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        try await StageSaver.save(authoredStage(), to: out, executor: exec)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(firstSize != nil)
    }
}

@Suite("StageSaver guard rails")
struct StageSaverErrorTests {

    @Test func rejectsUnsupportedExtension() async {
        await #expect(throws: StageSaver.SaveError.unsupportedExtension("obj")) {
            try await StageSaver.save(StageSnapshot(), to: URL(fileURLWithPath: "/tmp/x.obj"), executor: nil)
        }
    }

    @Test func binaryFormatsRequirePython() async {
        await #expect(throws: StageSaver.SaveError.pythonRequired("usdz")) {
            try await StageSaver.save(StageSnapshot(), to: URL(fileURLWithPath: "/tmp/x.usdz"), executor: nil)
        }
    }

    @Test func textFormatsSaveWithoutPython() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("x.usda")
        try await StageSaver.save(StageSnapshot(), to: out, executor: nil)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func errorDescriptionsAreHumanReadable() {
        #expect(StageSaver.SaveError.unsupportedExtension("obj").description.contains("obj"))
        #expect(StageSaver.SaveError.pythonRequired("usdc").description.contains("Python"))
    }
}
