import Foundation
import USDCore

/// Pure orbit-camera math (specs/viewport.md). RealityKit integration is
/// Phase 1; the math ships now because it is the unit-testable core the
/// viewport wraps ("unit for camera math" — specs/testing.md).
public struct OrbitCamera: Hashable, Sendable {

    /// Point the camera orbits, in stage units.
    public var target: SIMD3<Double>
    /// Distance from target (clamped to `distanceRange`).
    public var distance: Double
    /// Azimuth around the up axis, radians (wraps into [-π, π)).
    public var azimuth: Double
    /// Elevation from the horizon, radians (clamped shy of the poles).
    public var elevation: Double

    public static let distanceRange: ClosedRange<Double> = 0.001...10_000
    public static let elevationLimit = Double.pi / 2 - 0.01

    public init(
        target: SIMD3<Double> = .zero,
        distance: Double = 2,
        azimuth: Double = 0,
        elevation: Double = 0.3
    ) {
        self.target = target
        self.distance = Self.clampDistance(distance)
        self.azimuth = Self.wrapAzimuth(azimuth)
        self.elevation = Self.clampElevation(elevation)
    }

    // MARK: Gestures

    public mutating func orbit(deltaAzimuth: Double, deltaElevation: Double) {
        azimuth = Self.wrapAzimuth(azimuth + deltaAzimuth)
        elevation = Self.clampElevation(elevation + deltaElevation)
    }

    /// Exponential dolly: each unit of `amount` scales distance by e.
    public mutating func dolly(_ amount: Double) {
        distance = Self.clampDistance(distance * exp(amount))
    }

    public mutating func pan(_ delta: SIMD3<Double>) {
        target += delta
    }

    /// Frames a bounding sphere: recenters on it and backs off so the sphere
    /// fits a ~60° vertical FOV (the F key — specs/viewport.md).
    public mutating func frame(center: SIMD3<Double>, radius: Double) {
        target = center
        let fitDistance = max(radius, 1e-6) / tan(Double.pi / 6)
        distance = Self.clampDistance(fitDistance)
    }

    /// Camera position in stage space (Y-up spherical coordinates).
    public var position: SIMD3<Double> {
        let horizontal = distance * cos(elevation)
        return target + SIMD3(
            horizontal * sin(azimuth),
            distance * sin(elevation),
            horizontal * cos(azimuth))
    }

    // MARK: Clamping

    static func clampDistance(_ value: Double) -> Double {
        min(max(value, distanceRange.lowerBound), distanceRange.upperBound)
    }

    static func clampElevation(_ value: Double) -> Double {
        min(max(value, -elevationLimit), elevationLimit)
    }

    static func wrapAzimuth(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 2 * .pi)
        if wrapped >= .pi { wrapped -= 2 * .pi }
        if wrapped < -.pi { wrapped += 2 * .pi }
        return wrapped
    }
}
