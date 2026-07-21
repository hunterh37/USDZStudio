import Testing
import USDCore
import SculptKit
@testable import EditorUI

/// `SculptBuildRunner` applies SculptKit `BuildStep`s to the open document as
/// live, undoable commands — the in-app path that renders the sculpt build in
/// the viewport without a file (specs/sculpt-pipeline.md).
@Suite("SculptBuildRunner")
@MainActor
struct SculptBuildRunnerTests {

    private func house() -> ObjectSculptSpec { SculptDemos.lowPolyHouse() }

    @Test func blockoutAuthorsGeometryTree() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let authored = SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)

        // Group House + walls/roof/door/2 windows/chimney = 7 prims.
        #expect(authored.count == 7)
        let houseRoot = doc.snapshot.rootPrims.first { $0.name == "House" }
        #expect(houseRoot?.typeName == "Xform")
        let walls = houseRoot?.children.first { $0.name == "Walls" }
        #expect(walls?.children.first?.typeName == "Mesh")
        // The repetition copy is a real prim.
        #expect(houseRoot?.children.contains { $0.name == "Window_bay1" } == true)
    }

    @Test func structuralPlacesAndMaterialBinds() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        let placed = SculptBuildRunner.apply(pass: .structural, of: house(), to: doc)
        #expect(!placed.isEmpty)
        // Roof got a non-identity transform (translated up).
        let roof = doc.snapshot.prim(at: PrimPath("/House/Roof")!)
        #expect(roof?.attribute(named: "xformOp:transform") != nil)

        let materials = SculptBuildRunner.apply(pass: .material, of: house(), to: doc)
        #expect(!materials.isEmpty)   // painted leaves bound
    }

    @Test func playLiveRunsEveryPass() async {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        await SculptBuildRunner.playLive(house(), into: doc, passDelay: .milliseconds(1))
        let houseRoot = doc.snapshot.rootPrims.first { $0.name == "House" }
        #expect(houseRoot != nil)
        #expect(doc.canUndo)
    }

    @Test func skipsDuplicateAndInvalidSteps() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        let countAfterFirst = doc.snapshot.rootPrims.count
        // Re-running blockout is idempotent (existing sibling names are skipped).
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        #expect(doc.snapshot.rootPrims.count == countAfterFirst)

        // A transform step for a missing prim is skipped, not fatal.
        #expect(SculptBuildRunner.apply(
            step: .setTransform(path: "/Ghost", translation: [0, 0, 0],
                                rotationEulerDegrees: [0, 0, 0], scale: [1, 1, 1]),
            to: doc) == nil)
        // An unknown library entry is skipped.
        #expect(SculptBuildRunner.apply(
            step: .createLibraryMesh(name: "X", parentPath: nil, entryID: "prefab.ghost"),
            to: doc) == nil)
    }

    @Test func authorsRuntimeManifestAndSkipsMissingRoot() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        // Author the runtime manifest onto the existing root.
        let path = SculptBuildRunner.apply(
            step: .authorRuntime(rootPath: "/House", manifestJSON: "{\"nodes\":[\"House\"]}"),
            to: doc)
        #expect(path == "/House")
        #expect(doc.snapshot.prim(at: PrimPath("/House")!)?.attribute(named: "sculptRuntime") != nil)
        // A missing root prim is skipped, not fatal.
        #expect(SculptBuildRunner.apply(
            step: .authorRuntime(rootPath: "/Ghost", manifestJSON: "{}"), to: doc) == nil)
    }

    @Test func demoHouseSpecIsStrictQualityValid() {
        let spec = house()
        let assessment = PreSpecAssessment.assess(
            hints: ["cute low poly house", "cottage", "red roof"], width: 800, height: 600)
        let result = SpecValidator.validate(spec, assessment: assessment, strictQuality: true)
        #expect(result.isValid)
    }
}
