import Testing
import Foundation
@testable import ViewportKit

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("OrbitCamera")
struct OrbitCameraTests {

    @Test func initClampsAndWraps() {
        let camera = OrbitCamera(distance: -5, azimuth: 3 * .pi, elevation: 2)
        #expect(camera.distance == OrbitCamera.distanceRange.lowerBound)
        #expect(approx(camera.azimuth, -.pi))
        #expect(camera.elevation == OrbitCamera.elevationLimit)
    }

    @Test func orbitWrapsAzimuthAndClampsElevation() {
        var camera = OrbitCamera()
        camera.orbit(deltaAzimuth: 4 * .pi + 0.5, deltaElevation: -3)
        #expect(approx(camera.azimuth, 0.5))
        #expect(camera.elevation == -OrbitCamera.elevationLimit)
    }

    @Test func azimuthWrapBoundaries() {
        #expect(approx(OrbitCamera.wrapAzimuth(.pi), -.pi))
        #expect(approx(OrbitCamera.wrapAzimuth(-.pi), -.pi))
        #expect(approx(OrbitCamera.wrapAzimuth(0), 0))
    }

    @Test func dollyIsExponentialAndClamped() {
        var camera = OrbitCamera(distance: 2)
        camera.dolly(1)
        #expect(approx(camera.distance, 2 * exp(1)))
        camera.dolly(100)
        #expect(camera.distance == OrbitCamera.distanceRange.upperBound)
        camera.dolly(-1000)
        #expect(camera.distance == OrbitCamera.distanceRange.lowerBound)
    }

    @Test func panMovesTarget() {
        var camera = OrbitCamera()
        camera.pan(SIMD3(1, 2, 3))
        #expect(camera.target == SIMD3(1, 2, 3))
    }

    @Test func frameFitsSphere() {
        var camera = OrbitCamera()
        camera.frame(center: SIMD3(0, 1, 0), radius: 1)
        #expect(camera.target == SIMD3(0, 1, 0))
        #expect(approx(camera.distance, 1 / tan(Double.pi / 6)))
        // Degenerate radius must not produce zero/NaN distance.
        camera.frame(center: .zero, radius: 0)
        #expect(camera.distance >= OrbitCamera.distanceRange.lowerBound)
        #expect(camera.distance.isFinite)
    }

    @Test func positionSphericalMath() {
        // At azimuth 0, elevation 0: camera sits on +Z at `distance`.
        let camera = OrbitCamera(target: .zero, distance: 2, azimuth: 0, elevation: 0)
        #expect(approx(camera.position.x, 0))
        #expect(approx(camera.position.y, 0))
        #expect(approx(camera.position.z, 2))

        // Elevation π/4 lifts the camera.
        let raised = OrbitCamera(distance: 2, azimuth: 0, elevation: .pi / 4)
        #expect(approx(raised.position.y, 2 * sin(.pi / 4)))

        // Position is always `distance` away from target (invariant).
        var generatorState = 12345.0
        for _ in 0..<50 {
            generatorState = (generatorState * 1103515245 + 12345)
                .truncatingRemainder(dividingBy: 2_147_483_648)
            let camera = OrbitCamera(
                target: SIMD3(1, -2, 3),
                distance: 0.5 + generatorState.truncatingRemainder(dividingBy: 10),
                azimuth: generatorState.truncatingRemainder(dividingBy: 7),
                elevation: generatorState.truncatingRemainder(dividingBy: 1.4) - 0.7)
            let offset = camera.position - camera.target
            let length = (offset.x * offset.x + offset.y * offset.y + offset.z * offset.z).squareRoot()
            #expect(approx(length, camera.distance, tolerance: 1e-6))
        }
    }
}
