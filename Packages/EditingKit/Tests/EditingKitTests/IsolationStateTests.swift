import Testing
import USDCore
@testable import EditingKit

private func p(_ s: String) -> PrimPath { PrimPath(s)! }

private func stage() -> StageSnapshot {
    let hub = Prim(path: p("/Car/Wheels/FrontLeft/Hub"), typeName: "Mesh")
    let fl = Prim(path: p("/Car/Wheels/FrontLeft"), typeName: "Xform", children: [hub])
    let fr = Prim(path: p("/Car/Wheels/FrontRight"), typeName: "Xform")
    let wheels = Prim(path: p("/Car/Wheels"), typeName: "Xform", children: [fl, fr])
    let body = Prim(path: p("/Car/Body"), typeName: "Mesh")
    let car = Prim(path: p("/Car"), typeName: "Xform", children: [wheels, body])
    let light = Prim(path: p("/Light"), typeName: "SphereLight")
    return StageSnapshot(rootPrims: [car, light])
}

@Suite("IsolationState")
struct IsolationStateTests {

    @Test func inactiveShowsEverything() {
        let iso = IsolationState()
        #expect(!iso.isActive)
        #expect(iso.isVisible(p("/Light")))
        #expect(iso.hiddenPaths(in: stage()).isEmpty)
    }

    @Test func isolatingASubtreeShowsLineageAndSubtreeOnly() {
        let iso = IsolationState(roots: [p("/Car/Wheels/FrontLeft")])
        #expect(iso.isActive)
        // The isolated prim and its descendants render.
        #expect(iso.isVisible(p("/Car/Wheels/FrontLeft")))
        #expect(iso.isVisible(p("/Car/Wheels/FrontLeft/Hub")))
        // Ancestors render (needed to place it in the world).
        #expect(iso.isVisible(p("/Car")))
        #expect(iso.isVisible(p("/Car/Wheels")))
        // Siblings and unrelated branches are hidden.
        #expect(!iso.isVisible(p("/Car/Wheels/FrontRight")))
        #expect(!iso.isVisible(p("/Car/Body")))
        #expect(!iso.isVisible(p("/Light")))
    }

    @Test func hiddenPathsEnumeratesTheHiddenSet() {
        let iso = IsolationState(roots: [p("/Car/Wheels/FrontLeft")])
        #expect(iso.hiddenPaths(in: stage()) ==
                [p("/Car/Wheels/FrontRight"), p("/Car/Body"), p("/Light")])
    }

    @Test func multipleRootsUnionTheirLineages() {
        let iso = IsolationState(roots: [p("/Car/Body"), p("/Light")])
        #expect(iso.isVisible(p("/Car/Body")))
        #expect(iso.isVisible(p("/Light")))
        #expect(iso.isVisible(p("/Car")))
        #expect(!iso.isVisible(p("/Car/Wheels")))
    }

    @Test func normalizeDropsRedundantDescendantRoots() {
        let iso = IsolationState(roots: [p("/Car"), p("/Car/Wheels/FrontLeft")])
        #expect(iso.roots == [p("/Car")])
    }

    @Test func normalizeDropsStageRoot() {
        let iso = IsolationState(roots: [.root, p("/Car")])
        #expect(iso.roots == [p("/Car")])
        #expect(IsolationState(roots: [.root]).isActive == false)
    }

    @Test func isolatingReplacesRoots() {
        let iso = IsolationState(roots: [p("/Car")]).isolating([p("/Light")])
        #expect(iso.roots == [p("/Light")])
    }

    @Test func addingIsolationUnions() {
        let iso = IsolationState(roots: [p("/Car")]).addingIsolation([p("/Light")])
        #expect(iso.roots == [p("/Car"), p("/Light")])
    }

    @Test func clearedExitsIsolation() {
        #expect(!IsolationState(roots: [p("/Car")]).cleared().isActive)
    }
}
