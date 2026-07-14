import Testing
import USDCore
@testable import EditorUI

private func carStage() -> StageSnapshot {
    let frontLeft = Prim(path: PrimPath("/Car/Wheels/FrontLeft")!, typeName: "Mesh")
    let wheels = Prim(path: PrimPath("/Car/Wheels")!, typeName: "Xform", children: [frontLeft])
    let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh", visibility: .invisible)
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheels, body])
    return StageSnapshot(rootPrims: [car])
}

@Suite("Selection")
struct SelectionTests {

    let a = PrimPath("/A")!
    let b = PrimPath("/B")!

    @Test func plainClickReplaces() {
        let selection = Selection([a]).selecting(b)
        #expect(selection.paths == [b])
        #expect(selection.primary == b)
    }

    @Test func additiveClickTogglesMembership() {
        var selection = Selection([a]).selecting(b, additive: true)
        #expect(selection.paths == [a, b])
        selection = selection.selecting(a, additive: true)
        #expect(selection.paths == [b])
    }

    @Test func initDeduplicates() {
        #expect(Selection([a, b, a]).paths == [a, b])
        #expect(Selection.empty.isEmpty)
        #expect(Selection.empty.primary == nil)
        #expect(Selection([a]).contains(a))
        #expect(!Selection([a]).contains(b))
    }
}

@Suite("OutlinerModel")
struct OutlinerModelTests {

    let stage = carStage()

    @Test func rowsAreDepthFirstWithDepths() {
        let rows = OutlinerModel.rows(for: stage)
        #expect(rows.map(\.path.name) == ["Car", "Wheels", "FrontLeft", "Body"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1])
        #expect(rows[0].hasChildren && !rows[2].hasChildren)
        #expect(rows[3].visibility == .invisible)
        #expect(rows[0].id == rows[0].path)
    }

    @Test func collapsedSubtreesAreSkipped() {
        let rows = OutlinerModel.rows(for: stage, collapsed: [PrimPath("/Car/Wheels")!])
        #expect(rows.map(\.path.name) == ["Car", "Wheels", "Body"])
    }

    @Test func filterKeepsAncestorsOfMatches() {
        let rows = OutlinerModel.rows(for: stage)
        let filtered = OutlinerModel.filtered(rows, searchText: "frontleft")
        #expect(filtered.map(\.path.name) == ["Car", "Wheels", "FrontLeft"])
    }

    @Test func filterMatchesTypeNames() {
        let rows = OutlinerModel.rows(for: stage)
        let filtered = OutlinerModel.filtered(rows, searchText: "mesh")
        #expect(filtered.map(\.path.name) == ["Car", "Wheels", "FrontLeft", "Body"])
    }

    @Test func blankOrNoMatchFilters() {
        let rows = OutlinerModel.rows(for: stage)
        #expect(OutlinerModel.filtered(rows, searchText: "   ") == rows)
        #expect(OutlinerModel.filtered(rows, searchText: "zzz").isEmpty)
    }
}
