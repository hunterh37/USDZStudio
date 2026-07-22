import Testing
import USDCore
@testable import ViewportKit

@Suite("ViewportDragRouter — left-drag disambiguation matrix")
struct ViewportDragRouterTests {

    private let selPath = PrimPath("/Sel")!
    private let otherPath = PrimPath("/Other")!
    private var selection: Set<PrimPath> { [selPath] }

    private func resolve(_ hit: ViewportHit, _ mods: DragModifiers = .none,
                         box: Bool = false) -> DragIntent {
        ViewportDragRouter.resolve(hit: hit, selection: selection,
                                   modifiers: mods, boxSelectEnabled: box)
    }

    // 1. Handle always wins — even with the camera modifier or box-select on.
    @Test func handleAlwaysClaimsDrag() {
        #expect(resolve(.handle) == .gizmoHandle)
        #expect(resolve(.handle, .camera) == .gizmoHandle)
        #expect(resolve(.handle, box: true) == .gizmoHandle)
    }

    // 2. Camera modifier forces orbit (except over a handle, covered above).
    @Test func cameraModifierForcesOrbitEvenOnBody() {
        #expect(resolve(.prim(selPath), .camera) == .cameraOrbit)
        #expect(resolve(.empty, .camera) == .cameraOrbit)
        #expect(resolve(.prim(selPath), .camera, box: true) == .cameraOrbit)
    }

    // 3. Selected body → body-grab.
    @Test func selectedBodyStartsGrab() {
        #expect(resolve(.prim(selPath)) == .bodyGrab)
        #expect(resolve(.prim(selPath), box: true) == .bodyGrab) // grab beats marquee on-body
    }

    // 4a. Non-selected prim → marquee if enabled, else orbit.
    @Test func nonSelectedPrimYieldsToMarqueeOrOrbit() {
        #expect(resolve(.prim(otherPath)) == .cameraOrbit)
        #expect(resolve(.prim(otherPath), box: true) == .boxSelect)
    }

    // 4b. Empty space → marquee if enabled, else orbit.
    @Test func emptySpaceYieldsToMarqueeOrOrbit() {
        #expect(resolve(.empty) == .cameraOrbit)
        #expect(resolve(.empty, box: true) == .boxSelect)
    }

    // Exhaustive matrix sweep over every combination.
    @Test func exhaustiveMatrix() {
        let hits: [ViewportHit] = [.handle, .prim(selPath), .prim(otherPath), .empty]
        let mods: [DragModifiers] = [.none, .camera]
        for hit in hits {
            for mod in mods {
                for box in [false, true] {
                    let intent = ViewportDragRouter.resolve(
                        hit: hit, selection: selection, modifiers: mod, boxSelectEnabled: box)
                    let expected: DragIntent
                    if hit == .handle {
                        expected = .gizmoHandle
                    } else if mod.contains(.camera) {
                        expected = .cameraOrbit
                    } else if case let .prim(p) = hit, selection.contains(p) {
                        expected = .bodyGrab
                    } else {
                        expected = box ? .boxSelect : .cameraOrbit
                    }
                    #expect(intent == expected)
                }
            }
        }
    }

    @Test func modifierOptionSet() {
        #expect(DragModifiers.none.isEmpty)
        #expect(DragModifiers.camera.contains(.camera))
    }
}
