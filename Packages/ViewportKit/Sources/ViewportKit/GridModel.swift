import Foundation

/// Pure geometry for the ground grid + axis indicators (specs/viewport.md
/// "grid/axes"). Emits line segments; the RealityKit layer turns each into a
/// thin box entity.
public enum GridModel {

    public struct Segment: Hashable, Sendable {
        public let start: SIMD3<Float>
        public let end: SIMD3<Float>
        /// True for the two center lines (drawn brighter, as the axes).
        public let isAxis: Bool

        public init(start: SIMD3<Float>, end: SIMD3<Float>, isAxis: Bool) {
            self.start = start
            self.end = end
            self.isAxis = isAxis
        }

        public var length: Float {
            let d = end - start
            return (d * d).sum().squareRoot()
        }

        public var midpoint: SIMD3<Float> {
            (start + end) / 2
        }
    }

    /// Ground-plane (y = 0) grid centered on the origin. `divisions` lines on
    /// each side of center in each direction.
    public static func segments(halfExtent: Float, divisions: Int) -> [Segment] {
        guard halfExtent > 0, divisions > 0 else { return [] }
        let spacing = halfExtent / Float(divisions)
        var result: [Segment] = []
        for i in -divisions...divisions {
            let offset = Float(i) * spacing
            let isAxis = i == 0
            // Line parallel to X at z = offset.
            result.append(Segment(
                start: SIMD3(-halfExtent, 0, offset),
                end: SIMD3(halfExtent, 0, offset),
                isAxis: isAxis))
            // Line parallel to Z at x = offset.
            result.append(Segment(
                start: SIMD3(offset, 0, -halfExtent),
                end: SIMD3(offset, 0, halfExtent),
                isAxis: isAxis))
        }
        return result
    }

    /// Picks a grid half-extent that comfortably contains a model of the
    /// given bounding radius, snapped to a power-of-ten-ish nice number.
    public static func fittingHalfExtent(forModelRadius radius: Float) -> Float {
        guard radius.isFinite, radius > 0 else { return 1 }
        let needed = radius * 1.5
        let magnitude = pow(10, floor(log10(needed)))
        for multiplier: Float in [1, 2, 5, 10] where magnitude * multiplier >= needed {
            return magnitude * multiplier
        }
        return magnitude * 10
    }
}
