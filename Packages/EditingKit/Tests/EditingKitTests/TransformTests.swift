import Testing
import Foundation
import USDCore
@testable import EditingKit

private func approxEqual(_ a: [Double], _ b: [Double], tol: Double = 1e-9) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol }
}

@Suite("TRS ↔ matrix")
struct TRSTests {

    @Test func identityRoundTrips() {
        let m = TRS.identity.toMatrix()
        #expect(approxEqual(m, Matrix4.identity))
        let back = TRS.from(matrix: m)
        #expect(approxEqual(back.translation, [0, 0, 0]))
        #expect(approxEqual(back.scale, [1, 1, 1]))
    }

    @Test func translationLandsInLastRow() {
        let m = TRS(translation: [3, -4, 5]).toMatrix()
        #expect(m[12] == 3 && m[13] == -4 && m[14] == 5)
    }

    @Test func scaleOnDiagonal() {
        let m = TRS(scale: [2, 3, 4]).toMatrix()
        #expect(m[0] == 2 && m[5] == 3 && m[10] == 4)
    }

    @Test func translationScaleDecomposeRoundTrips() {
        let trs = TRS(translation: [10, 20, 30], scale: [2, 0.5, 4])
        let back = TRS.from(matrix: trs.toMatrix())
        #expect(approxEqual(back.translation, [10, 20, 30], tol: 1e-6))
        #expect(approxEqual(back.scale, [2, 0.5, 4], tol: 1e-6))
    }

    @Test func rotationDecomposeRoundTrips() {
        let trs = TRS(translation: [1, 2, 3], rotationEulerDegrees: [30, -45, 60])
        let back = TRS.from(matrix: trs.toMatrix())
        #expect(approxEqual(back.rotationEulerDegrees, [30, -45, 60], tol: 1e-6))
        #expect(approxEqual(back.translation, [1, 2, 3], tol: 1e-6))
    }
}

@Suite("TRS ↔ matrix — property-based round-trips")
struct TRSPropertyTests {

    /// A deterministic pseudo-random stream (seeded LCG) so the property sweep
    /// is reproducible in CI — the gizmo family's compose/decompose backbone
    /// must round-trip for arbitrary poses.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    @Test func decomposeThenRecomposeReconstructsTheMatrix() {
        var rng = LCG(state: 0xC0FFEE)
        for _ in 0..<500 {
            // Keep pitch away from ±90° (gimbal lock) and scale positive, the
            // regime the decompose assumes (no shear, proper rotation).
            let trs = TRS(
                translation: [rng.range(-50, 50), rng.range(-50, 50), rng.range(-50, 50)],
                rotationEulerDegrees: [rng.range(-179, 179), rng.range(-85, 85), rng.range(-179, 179)],
                scale: [rng.range(0.1, 8), rng.range(0.1, 8), rng.range(0.1, 8)])
            let m = trs.toMatrix()
            let round = TRS.from(matrix: m).toMatrix()
            #expect(approxEqual(round, m, tol: 1e-6))
        }
    }

    @Test func eulerRoundTripsWhenAwayFromGimbalLock() {
        var rng = LCG(state: 0x1234ABCD)
        for _ in 0..<500 {
            let euler = [rng.range(-179, 179), rng.range(-85, 85), rng.range(-179, 179)]
            let back = TRS.from(matrix: TRS(rotationEulerDegrees: euler).toMatrix())
            #expect(approxEqual(back.rotationEulerDegrees, euler, tol: 1e-6))
        }
    }
}

@Suite("SnapSettings")
struct SnapTests {

    @Test func translationSnapsToGrid() {
        let snap = SnapSettings(translation: 0.25)
        let out = snap.apply(to: TRS(translation: [0.3, 0.6, -0.1]))
        #expect(approxEqual(out.translation, [0.25, 0.5, 0.0], tol: 1e-9))
    }

    @Test func rotationSnapsToDegrees() {
        let snap = SnapSettings(rotationDegrees: 15)
        let out = snap.apply(to: TRS(rotationEulerDegrees: [7, 22, 44]))
        #expect(approxEqual(out.rotationEulerDegrees, [0, 15, 45], tol: 1e-9))
    }

    @Test func offLeavesValuesUntouched() {
        let trs = TRS(translation: [0.31, 0.62, 0.93])
        #expect(SnapSettings.off.apply(to: trs) == trs)
    }
}

private func stageWithXform() -> InMemoryStage {
    let node = Prim(path: PrimPath("/Root/Node")!, typeName: "Xform")
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [node])
    return InMemoryStage(StageSnapshot(rootPrims: [root]))
}

@Suite("Transform commands & drag")
struct TransformCommandTests {

    let path = PrimPath("/Root/Node")!

    @Test func readingUnauthoredTransformIsIdentity() {
        let stage = stageWithXform()
        #expect(stage.transform(at: path) == .identity)
    }

    @Test func setTransformCommandAuthorsAndUndoes() throws {
        let stage = stageWithXform()
        let stack = CommandStack(stage: stage)
        let command = SetTransformCommand(path: path,
                                          newTRS: TRS(translation: [1, 2, 3]),
                                          oldAttribute: nil, verb: "Move")
        try stack.run(command)
        #expect(approxEqual(stage.transform(at: path).translation, [1, 2, 3], tol: 1e-9))
        #expect(stack.undoLabel == "Move Node")
        try stack.undo()
        #expect(stage.transform(at: path) == .identity)
    }

    @Test func dragSessionCoalescesToOneUndoEntry() throws {
        let stage = stageWithXform()
        let stack = CommandStack(stage: stage)
        let drag = TransformDragSession(stage: stage, path: path, snap: SnapSettings(translation: 1))

        // Many live-preview frames (unsnapped inputs snap to the grid)…
        try drag.translate(by: [0.2, 0, 0])
        try drag.translate(by: [1.4, 0, 0])
        try drag.translate(by: [2.9, 0, 0])
        // …stage reflects the latest, but nothing recorded yet.
        #expect(!stack.canUndo)
        #expect(approxEqual(stage.transform(at: path).translation, [3, 0, 0], tol: 1e-9))

        // Commit once.
        let command = try #require(drag.makeCommand(verb: "Move"))
        try stack.run(command)
        #expect(stack.undoCount == 1)

        // One undo returns fully to the start.
        try stack.undo()
        #expect(stage.transform(at: path) == .identity)
    }

    @Test func dragCancelRestoresStart() throws {
        let stage = stageWithXform()
        // Pre-existing transform.
        try stage.apply(.setAttribute(path: path,
            attribute: Attribute(name: transformAttributeName, value: .matrix4(TRS(translation: [5, 5, 5]).toMatrix()))))
        let drag = TransformDragSession(stage: stage, path: path)
        try drag.translate(by: [10, 0, 0])
        #expect(approxEqual(stage.transform(at: path).translation, [15, 5, 5], tol: 1e-6))
        try drag.cancel()
        #expect(approxEqual(stage.transform(at: path).translation, [5, 5, 5], tol: 1e-6))
        #expect(drag.makeCommand() == nil)
    }

    @Test func unchangedDragMakesNoCommand() {
        let stage = stageWithXform()
        let drag = TransformDragSession(stage: stage, path: path)
        #expect(drag.makeCommand() == nil)
    }
}
