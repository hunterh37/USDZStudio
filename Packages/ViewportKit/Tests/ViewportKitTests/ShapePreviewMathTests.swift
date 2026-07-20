import XCTest
import simd
@testable import ViewportKit

final class ShapePreviewMathTests: XCTestCase {

    // MARK: bounds

    func testBoundsOfEmptyIsNil() {
        XCTAssertNil(ShapePreviewMath.bounds(of: []))
    }

    func testBoundsCentreAndRadius() {
        let cube: [SIMD3<Float>] = [
            [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
            [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1],
        ]
        let bounds = ShapePreviewMath.bounds(of: cube)
        let unwrapped = try! XCTUnwrap(bounds)
        XCTAssertEqual(unwrapped.center, SIMD3<Float>(0, 0, 0))
        // Farthest corner of a 2×2×2 cube from centre is √3.
        XCTAssertEqual(unwrapped.radius, sqrt(3), accuracy: 1e-5)
    }

    func testBoundsOffCentre() {
        let pts: [SIMD3<Float>] = [[2, 4, 6], [4, 8, 10]]
        let unwrapped = try! XCTUnwrap(ShapePreviewMath.bounds(of: pts))
        XCTAssertEqual(unwrapped.center, SIMD3<Float>(3, 6, 8))
        XCTAssertEqual(unwrapped.radius, simd_length(SIMD3<Float>(1, 2, 2)), accuracy: 1e-5)
    }

    func testBoundsSinglePointHasFloorRadius() {
        let unwrapped = try! XCTUnwrap(ShapePreviewMath.bounds(of: [[5, 5, 5]]))
        XCTAssertEqual(unwrapped.center, SIMD3<Float>(5, 5, 5))
        XCTAssertGreaterThan(unwrapped.radius, 0)
    }

    // MARK: framingDistance

    func testFramingDistanceFillsFrameWithMargin() {
        let radius = 1.0
        let distance = ShapePreviewMath.framingDistance(radius: radius, margin: 1)
        // At this distance the sphere of `radius` exactly subtends the vertical FOV.
        XCTAssertEqual(distance, radius / tan(OrbitCamera.verticalFOV / 2), accuracy: 1e-9)
    }

    func testFramingDistanceScalesWithRadiusAndMargin() {
        let base = ShapePreviewMath.framingDistance(radius: 1, margin: 1)
        XCTAssertEqual(ShapePreviewMath.framingDistance(radius: 3, margin: 1), base * 3, accuracy: 1e-9)
        XCTAssertEqual(ShapePreviewMath.framingDistance(radius: 1, margin: 2), base * 2, accuracy: 1e-9)
    }

    func testFramingDistanceMarginClampedToOne() {
        // A margin below 1 would let the shape overflow; it's clamped up to 1.
        let clamped = ShapePreviewMath.framingDistance(radius: 1, margin: 0.5)
        XCTAssertEqual(clamped, ShapePreviewMath.framingDistance(radius: 1, margin: 1), accuracy: 1e-9)
    }

    func testFramingDistanceHandlesZeroRadius() {
        XCTAssertGreaterThan(ShapePreviewMath.framingDistance(radius: 0), 0)
    }

    // MARK: turntableAngle

    func testTurntableAngleAtZeroIsZero() {
        XCTAssertEqual(ShapePreviewMath.turntableAngle(elapsed: 0, radiansPerSecond: 1), 0)
    }

    func testTurntableAngleLinearBeforeWrap() {
        XCTAssertEqual(ShapePreviewMath.turntableAngle(elapsed: 1, radiansPerSecond: 0.5), 0.5, accuracy: 1e-12)
    }

    func testTurntableAngleWrapsIntoRange() {
        let angle = ShapePreviewMath.turntableAngle(elapsed: 10, radiansPerSecond: 1)
        XCTAssertGreaterThanOrEqual(angle, 0)
        XCTAssertLessThan(angle, 2 * .pi)
        XCTAssertEqual(angle, 10 - 2 * .pi, accuracy: 1e-9) // 10 rad → 10 - 2π
    }

    func testTurntableAngleNegativeRateWrapsPositive() {
        let angle = ShapePreviewMath.turntableAngle(elapsed: 1, radiansPerSecond: -1)
        XCTAssertGreaterThanOrEqual(angle, 0)
        XCTAssertLessThan(angle, 2 * .pi)
        XCTAssertEqual(angle, 2 * .pi - 1, accuracy: 1e-9)
    }
}
