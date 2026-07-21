import Testing
@testable import EditorUI
import USDCore

/// Unit tests for the diff-panel row flattening and the document's baseline diff.
@MainActor
struct StageDiffPanelTests {

    @Test func summaryUsesEmDashForAbsentSides() {
        #expect(StageDiffRows.summary("a", "b") == "a → b")
        #expect(StageDiffRows.summary(nil, "b") == "— → b")
        #expect(StageDiffRows.summary("a", nil) == "a → —")
        #expect(StageDiffRows.summary(nil, nil) == "— → —")
    }

    @Test func emptyDiffYieldsNoRows() {
        let diff = StageDiff(metadata: [], addedPrims: [], removedPrims: [], changedPrims: [])
        #expect(StageDiffRows.rows(for: diff).isEmpty)
    }

    @Test func flattensEveryDiffSectionInOrder() {
        let path = PrimPath("/Cube")!
        let changedPath = PrimPath("/Sphere")!
        let diff = StageDiff(
            metadata: [.init(label: "upAxis", before: "Z", after: "Y")],
            addedPrims: [.init(path: path, typeName: "Mesh")],
            removedPrims: [.init(path: PrimPath("/Old")!, typeName: "")],
            changedPrims: [.init(path: changedPath,
                                 changes: [.init(label: "visibility",
                                                 before: "inherited", after: "invisible")])]
        )
        let rows = StageDiffRows.rows(for: diff)
        #expect(rows.count == 4)
        #expect(rows[0].kind == .metadata)
        #expect(rows[0].title == "upAxis")
        #expect(rows[0].detail == "Z → Y")
        #expect(rows[0].path == nil)

        #expect(rows[1].kind == .added)
        #expect(rows[1].detail == "Mesh")
        #expect(rows[1].path == path)

        // Empty type name falls back to "prim".
        #expect(rows[2].kind == .removed)
        #expect(rows[2].detail == "prim")

        #expect(rows[3].kind == .changed)
        #expect(rows[3].title == "/Sphere · visibility")
        #expect(rows[3].path == changedPath)
    }

    @Test func documentBaselineDiffIsEmptyUntilEdited() {
        let doc = EditorDocument()
        #expect(doc.diffFromBaseline.isEmpty)
    }

    @Test func rowsAreIdentifiableUniquely() {
        let path = PrimPath("/A")!
        let diff = StageDiff(
            metadata: [],
            addedPrims: [],
            removedPrims: [],
            changedPrims: [.init(path: path, changes: [
                .init(label: "active", before: "true", after: "false"),
                .init(label: "visibility", before: "inherited", after: "invisible"),
            ])]
        )
        let ids = Set(StageDiffRows.rows(for: diff).map(\.id))
        #expect(ids.count == 2)
    }
}
