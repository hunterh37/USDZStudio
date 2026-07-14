import Foundation

/// Camera basis vectors + screen-space pan mapping (specs/viewport.md).
/// Pure math, unit-tested; the RealityKit layer only consumes the results.
extension OrbitCamera {

    /// Unit vector from the camera toward the target.
    public var forwardVector: SIMD3<Double> {
        normalized(target - position)
    }

    /// Camera-space right, horizontal by construction (elevation is clamped
    /// shy of the poles so this never degenerates).
    public var rightVector: SIMD3<Double> {
        normalized(cross(forwardVector, SIMD3(0, 1, 0)))
    }

    /// Camera-space up (orthonormal with forward/right).
    public var upVector: SIMD3<Double> {
        cross(rightVector, forwardVector)
    }

    /// Vertical field of view used for framing and pan scaling, radians.
    public static let verticalFOV = Double.pi / 3

    /// Pans so content tracks the cursor 1:1 at the target depth: a drag of
    /// `deltaY` points moves the target by the world-space size of those
    /// points on the focal plane.
    public mutating func panByScreenDelta(
        deltaX: Double,
        deltaY: Double,
        viewportHeight: Double
    ) {
        guard viewportHeight > 0 else { return }
        let worldPerPoint = 2 * distance * tan(Self.verticalFOV / 2) / viewportHeight
        pan(rightVector * (-deltaX * worldPerPoint) + upVector * (deltaY * worldPerPoint))
    }

    private func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = (v * v).sum().squareRoot()
        guard length > 1e-12 else { return SIMD3(0, 0, -1) }
        return v / length
    }

    private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x)
    }
}
