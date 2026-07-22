import Testing
import Foundation
import simd
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

private func approx(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
private func approx(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-6) -> Bool {
    approx(a.x, b.x, tol: tol) && approx(a.y, b.y, tol: tol) && approx(a.z, b.z, tol: tol)
}

// MARK: - NumericEntry grammar

@Suite("NumericEntry — typing grammar")
struct NumericEntryTests {

    @Test func emptyParsesToNil() {
        #expect(NumericEntry.empty.value == nil)
        #expect(NumericEntry.empty.isEmpty)
    }

    @Test func digitsAccumulateAndParse() {
        var e = NumericEntry.empty
        for c in "24" { e.append(c) }
        #expect(e.text == "24")
        #expect(e.value == 24)
        #expect(!e.isEmpty)
    }

    @Test func oneDotMax() {
        var e = NumericEntry.empty
        for c in "2.4" { e.append(c) }
        e.append(".")                    // rejected: already a dot
        #expect(e.text == "2.4")
        #expect(approx(e.value ?? .nan, 2.4))
    }

    @Test func leadingDotParses() {
        var e = NumericEntry.empty
        for c in ".5" { e.append(c) }
        #expect(approx(e.value ?? .nan, 0.5))
    }

    @Test func minusOnlyLeading() {
        var e = NumericEntry.empty
        e.append("-")
        for c in "3" { e.append(c) }
        e.append("-")                    // rejected: not first
        #expect(e.text == "-3")
        #expect(e.value == -3)
    }

    @Test func partialBuffersParseToNil() {
        var dash = NumericEntry.empty; dash.append("-")
        #expect(dash.value == nil)
        var dot = NumericEntry.empty; dot.append(".")
        #expect(dot.value == nil)
    }

    @Test func lettersRejected() {
        var e = NumericEntry.empty
        e.append("a"); e.append("Z"); e.append("+")
        #expect(e.isEmpty)
    }

    @Test func backspaceRemovesLastAndNoOpsWhenEmpty() {
        var e = NumericEntry(text: "2.4")
        e.backspace()
        #expect(e.text == "2.")
        var empty = NumericEntry.empty
        empty.backspace()
        #expect(empty.isEmpty)
    }
}

// MARK: - Kind mapping

@Suite("ModalTransformKind — key + verb mapping")
struct ModalTransformKindTests {

    @Test func shortcutsMapBothWays() {
        #expect(ModalTransformKind.forShortcut("g") == .grab)
        #expect(ModalTransformKind.forShortcut("R") == .rotate)   // case-insensitive
        #expect(ModalTransformKind.forShortcut("s") == .scale)
        #expect(ModalTransformKind.forShortcut("w") == nil)       // W is a gizmo key
        #expect(ModalTransformKind.grab.shortcut == "g")
        #expect(ModalTransformKind.rotate.shortcut == "r")
        #expect(ModalTransformKind.scale.shortcut == "s")
    }

    @Test func undoVerbs() {
        #expect(ModalTransformKind.grab.undoVerb == "Move")
        #expect(ModalTransformKind.rotate.undoVerb == "Rotate")
        #expect(ModalTransformKind.scale.undoVerb == "Scale")
    }

    @Test func opIdentities() {
        #expect(ModalOp.identity(for: .grab) == .translate(.zero))
        #expect(ModalOp.identity(for: .rotate) == .rotate(axis: SIMD3(0, 0, 1), degrees: 0))
        #expect(ModalOp.identity(for: .scale) == .scale(basis: .world, factors: SIMD3(1, 1, 1)))
    }
}

// MARK: - Constraint state machine

@Suite("ModalTransform — constraint state machine")
struct ModalConstraintTests {

    private func grab() -> ModalTransform { ModalTransform(kind: .grab, pivot: .zero) }

    @Test func axisPressLocksAxisWorld() {
        var m = grab()
        m.setConstraint(axis: .x, shift: false)
        #expect(m.constraint == .axis(.x, local: false))
        #expect(m.lastAxis == .x)
    }

    @Test func repeatSameAxisTogglesLocal() {
        var m = grab()
        m.setConstraint(axis: .x, shift: false)
        m.setConstraint(axis: .x, shift: false)          // XX → local
        #expect(m.constraint == .axis(.x, local: true))
        m.setConstraint(axis: .x, shift: false)          // XXX → back to world
        #expect(m.constraint == .axis(.x, local: false))
    }

    @Test func differentAxisResetsToWorld() {
        var m = grab()
        m.setConstraint(axis: .x, shift: false)
        m.setConstraint(axis: .x, shift: false)          // local
        m.setConstraint(axis: .y, shift: false)          // switch axis → world
        #expect(m.constraint == .axis(.y, local: false))
    }

    @Test func shiftLocksPlaneAndRepeatTogglesLocal() {
        var m = grab()
        m.setConstraint(axis: .z, shift: true)
        #expect(m.constraint == .plane(.z, local: false))
        m.setConstraint(axis: .z, shift: true)
        #expect(m.constraint == .plane(.z, local: true))
    }

    @Test func axisThenShiftSwitchesToPlane() {
        var m = grab()
        m.setConstraint(axis: .x, shift: false)
        m.setConstraint(axis: .x, shift: true)
        #expect(m.constraint == .plane(.x, local: false))
    }

    @Test func seededConstraintTracksLastAxis() {
        let a = ModalTransform(kind: .grab, pivot: .zero, constraint: .axis(.y, local: true))
        #expect(a.lastAxis == .y)
        let p = ModalTransform(kind: .grab, pivot: .zero, constraint: .plane(.z, local: false))
        #expect(p.lastAxis == .z)
    }
}

// MARK: - Grab math

@Suite("ModalTransform — grab / translate")
struct ModalGrabTests {

    /// A ray straight down -Z from z=5 at screen offset (x, y).
    private func downRay(x: Double, y: Double) -> Ray {
        Ray(origin: SIMD3(x, y, 5), direction: SIMD3(0, 0, -1))
    }

    private let p0 = CGPoint.zero

    @Test func axisConstrainedGrabMatchesAxisParameter() {
        // Grab locked to X: the delta must equal ExtrudeGizmoMath.axisParameter's
        // difference along +X (asserts reuse, not a fork, of the gizmo math).
        var m = ModalTransform(kind: .grab, pivot: .zero)
        m.setConstraint(axis: .x, shift: false)
        let start = downRay(x: 0, y: 0)
        let cur = downRay(x: 2, y: 0)
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: start, currentRay: cur)
        let dir = SIMD3<Double>(1, 0, 0)
        let t0 = ExtrudeGizmoMath.axisParameter(ray: start, origin: .zero, axis: dir)!
        let t1 = ExtrudeGizmoMath.axisParameter(ray: cur, origin: .zero, axis: dir)!
        #expect(op == .translate(dir * (t1 - t0)))
        #expect(op == .translate(SIMD3(2, 0, 0)))
    }

    @Test func freeGrabMovesInViewPlane() {
        // Camera looks down -Z, so the view plane is XY; a screen move of +2 X
        // and +1 Y maps straight to a world (2, 1, 0) delta.
        let m = ModalTransform(kind: .grab, pivot: .zero)
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: downRay(x: 0, y: 0), currentRay: downRay(x: 2, y: 1))
        guard case let .translate(d) = op else { Issue.record("not translate"); return }
        #expect(approx(d, SIMD3(2, 1, 0)))
    }

    @Test func planeGrabDropsNormalComponent() {
        // Plane ⊥Z: a would-be free delta with a Z component keeps only XY.
        var m = ModalTransform(kind: .grab, pivot: .zero)
        m.setConstraint(axis: .z, shift: true)
        // Rays that hit the XY plane; the free delta is purely in-plane here, so
        // dropping the (zero) Z component leaves it unchanged.
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: downRay(x: 0, y: 0), currentRay: downRay(x: 3, y: -2))
        guard case let .translate(d) = op else { Issue.record("not translate"); return }
        #expect(approx(d.z, 0))
        #expect(approx(d, SIMD3(3, -2, 0)))
    }

    @Test func numericOverrideIgnoresPointer() {
        // G Z 2.4 ⏎ → translate 2.4 along Z regardless of pointer position.
        var m = ModalTransform(kind: .grab, pivot: .zero)
        m.setConstraint(axis: .z, shift: false)
        m.typeDigit("2"); m.typeDigit("."); m.typeDigit("4")
        let op = m.proposedOp(pointer: CGPoint(x: 999, y: 999), start: p0, pivotScreen: p0,
                              startRay: downRay(x: 0, y: 0), currentRay: downRay(x: 5, y: 5))
        guard case let .translate(d) = op else { Issue.record("not translate"); return }
        #expect(approx(d, SIMD3(0, 0, 2.4)))
    }

    @Test func numericFreeDefaultsToLastAxisThenX() {
        var m = ModalTransform(kind: .grab, pivot: .zero)   // free, no axis chosen
        m.typeDigit("3")
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: downRay(x: 0, y: 0), currentRay: downRay(x: 0, y: 0))
        #expect(op == .translate(SIMD3(3, 0, 0)))          // defaults to X
    }

    @Test func parallelAxisRayProposesZero() {
        // A ray parallel to the constrained axis → axisParameter nil → no move.
        var m = ModalTransform(kind: .grab, pivot: .zero)
        m.setConstraint(axis: .z, shift: false)
        let along = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1)) // parallel to Z
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: along, currentRay: along)
        #expect(op == .translate(.zero))
    }

    @Test func localAxisUsesSelectionBasis() {
        // Local basis with X mapped to world +Y: an X-locked grab moves in world Y.
        let basis = GizmoBasis(x: SIMD3(0, 1, 0), y: SIMD3(-1, 0, 0), z: SIMD3(0, 0, 1))
        var m = ModalTransform(kind: .grab, pivot: .zero, basis: basis)
        m.setConstraint(axis: .x, shift: false)
        m.setConstraint(axis: .x, shift: false)            // → local
        m.typeDigit("2")
        let op = m.proposedOp(pointer: p0, start: p0, pivotScreen: p0,
                              startRay: Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1)),
                              currentRay: Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1)))
        guard case let .translate(d) = op else { Issue.record("not translate"); return }
        #expect(approx(d, SIMD3(0, 2, 0)))
    }
}

// MARK: - Rotate math

@Suite("ModalTransform — rotate")
struct ModalRotateTests {

    @Test func numericRotateUsesTypedDegrees() {
        var m = ModalTransform(kind: .rotate, pivot: .zero)
        m.setConstraint(axis: .y, shift: false)
        m.typeDigit("9"); m.typeDigit("0")
        let ray = CameraRay.Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: .zero,
                              startRay: ray, currentRay: ray)
        #expect(op == .rotate(axis: SIMD3(0, 1, 0), degrees: 90))
    }

    @Test func pointerRotateMatchesSignedAngle() {
        // Axis-constrained rotate must equal RotateGizmoMath's swept angle about
        // the same axis (reuse, not fork).
        var m = ModalTransform(kind: .rotate, pivot: .zero)
        m.setConstraint(axis: .z, shift: false)
        let start = CameraRay.Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let cur = CameraRay.Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        let expected = RotateGizmoMath.signedAngleDegrees(
            from: start, to: cur, origin: .zero, axis: SIMD3(0, 0, 1))!
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: .zero,
                              startRay: start, currentRay: cur)
        guard case let .rotate(axis, deg) = op else { Issue.record("not rotate"); return }
        #expect(approx(axis, SIMD3(0, 0, 1)))
        #expect(approx(deg, expected))
        #expect(approx(deg, 90))
    }

    @Test func freeRotateUsesViewAxis() {
        // Unconstrained rotate spins about the camera→pivot view axis.
        let m = ModalTransform(kind: .rotate, pivot: .zero)
        // Camera on the +Z axis: the view axis (camera → pivot) is exactly -Z.
        let start = CameraRay.Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        let cur = CameraRay.Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: .zero,
                              startRay: start, currentRay: cur)
        guard case let .rotate(axis, _) = op else { Issue.record("not rotate"); return }
        // camera at +Z looking at origin → view axis toward -Z.
        #expect(approx(axis, SIMD3(0, 0, -1)))
    }
}

// MARK: - Scale math

@Suite("ModalTransform — scale")
struct ModalScaleTests {

    private let pivotScreen = CGPoint(x: 100, y: 100)

    @Test func freeScaleIsUniformRadiusRatio() {
        // Start 10px out, drag to 20px out → factor 2 uniform.
        let m = ModalTransform(kind: .scale, pivot: .zero)
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: CGPoint(x: 120, y: 100),
                              start: CGPoint(x: 110, y: 100),
                              pivotScreen: pivotScreen, startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: .world, factors: SIMD3(2, 2, 2)))
    }

    @Test func degenerateStartGuardsToIdentity() {
        let m = ModalTransform(kind: .scale, pivot: .zero)
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: CGPoint(x: 120, y: 100),
                              start: pivotScreen,             // start exactly at pivot
                              pivotScreen: pivotScreen, startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: .world, factors: SIMD3(1, 1, 1)))
    }

    @Test func numericFactorIdentityAtOne() {
        var m = ModalTransform(kind: .scale, pivot: .zero)
        m.typeDigit("1")
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: CGPoint(x: 999, y: 999), start: .zero,
                              pivotScreen: pivotScreen, startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: .world, factors: SIMD3(1, 1, 1)))
    }

    @Test func axisScaleAppliesFactorToOneAxis() {
        var m = ModalTransform(kind: .scale, pivot: .zero)
        m.setConstraint(axis: .y, shift: false)
        m.typeDigit("3")
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: pivotScreen,
                              startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: .world, factors: SIMD3(1, 3, 1)))
    }

    @Test func planeScaleLeavesNormalAxis() {
        var m = ModalTransform(kind: .scale, pivot: .zero)
        m.setConstraint(axis: .z, shift: true)              // plane ⊥Z
        m.typeDigit("2")
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: pivotScreen,
                              startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: .world, factors: SIMD3(2, 2, 1)))
    }

    @Test func localAxisScaleUsesBasis() {
        let basis = GizmoBasis(x: SIMD3(0, 1, 0), y: SIMD3(-1, 0, 0), z: SIMD3(0, 0, 1))
        var m = ModalTransform(kind: .scale, pivot: .zero, basis: basis)
        m.setConstraint(axis: .x, shift: false)
        m.setConstraint(axis: .x, shift: false)             // local
        m.typeDigit("4")
        let dummy = CameraRay.Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let op = m.proposedOp(pointer: .zero, start: .zero, pivotScreen: pivotScreen,
                              startRay: dummy, currentRay: dummy)
        #expect(op == .scale(basis: basis, factors: SIMD3(4, 1, 1)))
    }
}

// MARK: - HUD golden strings

@Suite("ModalTransform — hudText goldens")
struct ModalHUDTests {

    @Test func freeStates() {
        #expect(ModalTransform(kind: .grab, pivot: .zero).hudText == "Move")
        #expect(ModalTransform(kind: .rotate, pivot: .zero).hudText == "Rotate")
        #expect(ModalTransform(kind: .scale, pivot: .zero).hudText == "Scale")
    }

    @Test func freeWithNumeric() {
        var m = ModalTransform(kind: .scale, pivot: .zero)
        m.typeDigit("2")
        #expect(m.hudText == "Scale: 2")
    }

    @Test func axisStates() {
        var m = ModalTransform(kind: .grab, pivot: .zero)
        m.setConstraint(axis: .z, shift: false)
        #expect(m.hudText == "Move Z (global)")
        m.typeDigit("2"); m.typeDigit("."); m.typeDigit("4")
        #expect(m.hudText == "Move Z: 2.4 (global)")
        m.setConstraint(axis: .z, shift: false)             // → local
        #expect(m.hudText == "Move Z: 2.4 (local)")
    }

    @Test func rotateAxisLocal() {
        var m = ModalTransform(kind: .rotate, pivot: .zero)
        m.setConstraint(axis: .y, shift: false)
        m.setConstraint(axis: .y, shift: false)
        m.typeDigit("9"); m.typeDigit("0")
        #expect(m.hudText == "Rotate Y: 90 (local)")
    }

    @Test func planeStates() {
        var mz = ModalTransform(kind: .grab, pivot: .zero); mz.setConstraint(axis: .z, shift: true)
        #expect(mz.hudText == "Move plane XY (global)")
        var mx = ModalTransform(kind: .grab, pivot: .zero); mx.setConstraint(axis: .x, shift: true)
        #expect(mx.hudText == "Move plane YZ (global)")
        var my = ModalTransform(kind: .grab, pivot: .zero); my.setConstraint(axis: .y, shift: true)
        my.typeDigit("5")
        #expect(my.hudText == "Move plane XZ: 5 (global)")
    }
}
