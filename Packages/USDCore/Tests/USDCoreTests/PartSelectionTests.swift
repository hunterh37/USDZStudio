import Testing
import USDCore

/// A `/Car/Wheels/FrontLeft/Hub` tree for exercising drill-down.
private func carStage() -> StageSnapshot {
    let hub = Prim(path: PrimPath("/Car/Wheels/FrontLeft/Hub")!, typeName: "Mesh")
    let fl = Prim(path: PrimPath("/Car/Wheels/FrontLeft")!, typeName: "Xform", children: [hub])
    let wheels = Prim(path: PrimPath("/Car/Wheels")!, typeName: "Xform", children: [fl])
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheels])
    return StageSnapshot(rootPrims: [car])
}

private func p(_ s: String) -> PrimPath { PrimPath(s)! }

@Suite("PartSelection.ancestorChain")
struct AncestorChainTests {
    @Test func chainRunsTopDownIncludingLeaf() {
        #expect(PartSelection.ancestorChain(of: p("/Car/Wheels/FrontLeft")) ==
                [p("/Car"), p("/Car/Wheels"), p("/Car/Wheels/FrontLeft")])
    }
    @Test func singleComponentIsItself() {
        #expect(PartSelection.ancestorChain(of: p("/Car")) == [p("/Car")])
    }
    @Test func rootHasEmptyChain() {
        #expect(PartSelection.ancestorChain(of: .root).isEmpty)
    }
}

@Suite("PartSelection.drillDown")
struct DrillDownTests {
    private let leaf = PrimPath("/Car/Wheels/FrontLeft/Hub")!

    @Test func freshClickSelectsTopLevelObject() {
        #expect(PartSelection.drillDown(picked: leaf, from: nil) == PrimPath("/Car")!)
    }

    @Test func clickingDifferentObjectGrabsItsTopLevel() {
        // Current selection is on an unrelated branch.
        let other = PrimPath("/Light")!
        #expect(PartSelection.drillDown(picked: leaf, from: other) == PrimPath("/Car")!)
    }

    @Test func repeatedClicksDrillOneLevelDeeperEachTime() {
        var current: PrimPath? = nil
        let expected = [
            PrimPath("/Car")!,
            PrimPath("/Car/Wheels")!,
            PrimPath("/Car/Wheels/FrontLeft")!,
            PrimPath("/Car/Wheels/FrontLeft/Hub")!,
        ]
        for step in expected {
            current = PartSelection.drillDown(picked: leaf, from: current)
            #expect(current == step)
        }
    }

    @Test func atLeafStaysAtLeaf() {
        #expect(PartSelection.drillDown(picked: leaf, from: leaf) == leaf)
    }

    @Test func pickingRootReturnsNil() {
        #expect(PartSelection.drillDown(picked: .root, from: nil) == nil)
    }

    @Test func pickingShallowLeafSelectsItDirectly() {
        let shallow = PrimPath("/Car")!
        #expect(PartSelection.drillDown(picked: shallow, from: nil) == shallow)
        #expect(PartSelection.drillDown(picked: shallow, from: shallow) == shallow)
    }
}

@Suite("PartSelection.walkUp")
struct WalkUpTests {
    @Test func walksToParent() {
        #expect(PartSelection.walkUp(from: p("/Car/Wheels/FrontLeft")) == p("/Car/Wheels"))
    }
    @Test func stopsAtTopLevel() {
        #expect(PartSelection.walkUp(from: p("/Car")) == nil)
    }
    @Test func rootHasNoParent() {
        #expect(PartSelection.walkUp(from: .root) == nil)
    }
}

@Suite("PartSelection.breadcrumb")
struct BreadcrumbTests {
    @Test func resolvesNamesAndTypes() {
        let crumbs = PartSelection.breadcrumb(to: p("/Car/Wheels/FrontLeft"), in: carStage())
        #expect(crumbs.map(\.name) == ["Car", "Wheels", "FrontLeft"])
        #expect(crumbs.map(\.typeName) == ["Xform", "Xform", "Xform"])
        #expect(crumbs.map(\.path) == [p("/Car"), p("/Car/Wheels"), p("/Car/Wheels/FrontLeft")])
        #expect(crumbs.first?.id == p("/Car"))
    }

    @Test func rootPathHasNoCrumbs() {
        #expect(PartSelection.breadcrumb(to: .root, in: carStage()).isEmpty)
    }

    @Test func missingPrimGetsEmptyType() {
        let crumbs = PartSelection.breadcrumb(to: p("/Car/Ghost"), in: carStage())
        #expect(crumbs.map(\.name) == ["Car", "Ghost"])
        #expect(crumbs.last?.typeName == "")
    }
}
