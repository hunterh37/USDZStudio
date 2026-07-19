import Testing
@testable import ViewportKit

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("AxisGizmoModel")
struct AxisGizmoModelTests {

    /// Camera at azimuth 0, elevation 0 sits on +Z looking down −Z:
    /// +X projects to the right, +Y up (screen-space −Y), +Z toward viewer.
    @Test func projectionFromFrontView() {
        let camera = OrbitCamera(distance: 2, azimuth: 0, elevation: 0)
        let tips = AxisGizmoModel.tips(camera: camera)
        let byAxis = Dictionary(uniqueKeysWithValues: tips.map { ($0.axis, $0) })

        let xPos = byAxis[.xPositive]!
        #expect(approx(xPos.offsetX, 1) && approx(xPos.offsetY, 0) && approx(xPos.depth, 0))
        let yPos = byAxis[.yPositive]!
        #expect(approx(yPos.offsetX, 0) && approx(yPos.offsetY, -1) && approx(yPos.depth, 0))
        let zPos = byAxis[.zPositive]!
        // +Z points at the viewer: no screen offset, negative depth.
        #expect(approx(zPos.offsetX, 0) && approx(zPos.offsetY, 0) && approx(zPos.depth, -1))
        let zNeg = byAxis[.zNegative]!
        #expect(approx(zNeg.depth, 1))
    }

    @Test func tipsAreSortedBackToFront() {
        let camera = OrbitCamera(distance: 2, azimuth: 0.7, elevation: 0.4)
        let depths = AxisGizmoModel.tips(camera: camera).map(\.depth)
        #expect(depths == depths.sorted(by: >))
    }

    @Test func oppositeAxesMirror() {
        let camera = OrbitCamera(distance: 2, azimuth: 1.1, elevation: -0.3)
        let byAxis = Dictionary(uniqueKeysWithValues:
            AxisGizmoModel.tips(camera: camera).map { ($0.axis, $0) })
        for (pos, neg): (AxisGizmoModel.HalfAxis, AxisGizmoModel.HalfAxis)
            in [(.xPositive, .xNegative), (.yPositive, .yNegative), (.zPositive, .zNegative)] {
            #expect(approx(byAxis[pos]!.offsetX, -byAxis[neg]!.offsetX))
            #expect(approx(byAxis[pos]!.offsetY, -byAxis[neg]!.offsetY))
            #expect(approx(byAxis[pos]!.depth, -byAxis[neg]!.depth))
        }
    }

    @Test func hitTestFindsTipAndMissesElsewhere() {
        let camera = OrbitCamera(distance: 2, azimuth: 0, elevation: 0)
        // +X tip sits at (radius, 0).
        #expect(AxisGizmoModel.hitTest(x: 30, y: 0, radius: 30, hitRadius: 8,
                                       camera: camera) == .xPositive)
        // +Y tip at (0, -radius).
        #expect(AxisGizmoModel.hitTest(x: 0, y: -30, radius: 30, hitRadius: 8,
                                       camera: camera) == .yPositive)
        // Between tips: nothing.
        #expect(AxisGizmoModel.hitTest(x: 20, y: -20, radius: 30, hitRadius: 8,
                                       camera: camera) == nil)
    }

    /// Both Z tips project onto the gizmo center from the front view; the
    /// front-most one (+Z, toward the viewer) must win the hit test.
    @Test func hitTestPrefersFrontMostTip() {
        let camera = OrbitCamera(distance: 2, azimuth: 0, elevation: 0)
        #expect(AxisGizmoModel.hitTest(x: 0, y: 0, radius: 30, hitRadius: 8,
                                       camera: camera) == .zPositive)
    }

    @Test func presetsLookDownEachAxis() {
        for axis in AxisGizmoModel.HalfAxis.allCases {
            let preset = AxisGizmoModel.preset(for: axis, currentAzimuth: 0.42)
            var camera = OrbitCamera(distance: 3)
            camera.azimuth = preset.azimuth
            camera.elevation = preset.elevation
            // The camera should sit on the clicked half-axis side of the target.
            let offset = camera.position - camera.target
            let dot = offset.x * axis.direction.x + offset.y * axis.direction.y
                + offset.z * axis.direction.z
            #expect(dot > 0.9 * camera.distance,
                    "camera not aligned with \(axis)")
        }
    }

    @Test func topBottomPresetsKeepAzimuth() {
        #expect(approx(AxisGizmoModel.preset(for: .yPositive, currentAzimuth: 1.2).azimuth, 1.2))
        #expect(approx(AxisGizmoModel.preset(for: .yNegative, currentAzimuth: -0.8).azimuth, -0.8))
    }

    @Test func elevationPresetsStayWithinClampRange() {
        for axis in AxisGizmoModel.HalfAxis.allCases {
            let preset = AxisGizmoModel.preset(for: axis, currentAzimuth: 0)
            #expect(abs(preset.elevation) <= OrbitCamera.elevationLimit)
        }
    }
}
