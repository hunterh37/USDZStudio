import Foundation
import USDCore

/// A translate/rotate/scale decomposition of a prim's local transform.
///
/// Stored the way the inspector edits it: translation in scene units, rotation
/// as XYZ Euler angles in **degrees**, and per-axis scale. Round-trips through
/// a USD `xformOp:transform` matrix (`matrix4d`, row-major, row-vector
/// convention — translation lives in the last row).
public struct TRS: Hashable, Sendable {
    public var translation: [Double]  // [x, y, z]
    public var rotationEulerDegrees: [Double]  // [rx, ry, rz], applied X→Y→Z
    public var scale: [Double]  // [sx, sy, sz]

    public static let identity = TRS(translation: [0, 0, 0],
                                     rotationEulerDegrees: [0, 0, 0],
                                     scale: [1, 1, 1])

    public init(translation: [Double] = [0, 0, 0],
                rotationEulerDegrees: [Double] = [0, 0, 0],
                scale: [Double] = [1, 1, 1]) {
        self.translation = translation
        self.rotationEulerDegrees = rotationEulerDegrees
        self.scale = scale
    }
}

/// Row-major 4×4 matrix helpers using USD's row-vector convention (`p' = p·M`).
public enum Matrix4 {
    public static let identity: [Double] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    /// `a · b`, both row-major 4×4.
    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[r * 4 + k] * b[k * 4 + c] }
                out[r * 4 + c] = sum
            }
        }
        return out
    }

    static func translation(_ t: [Double]) -> [Double] {
        var m = identity
        m[12] = t[0]; m[13] = t[1]; m[14] = t[2]
        return m
    }

    static func scale(_ s: [Double]) -> [Double] {
        var m = identity
        m[0] = s[0]; m[5] = s[1]; m[10] = s[2]
        return m
    }

    // Row-vector rotation matrices (transpose of the column-vector forms).
    static func rotationX(_ rad: Double) -> [Double] {
        let c = cos(rad), s = sin(rad)
        return [1, 0, 0, 0,
                0, c, s, 0,
                0, -s, c, 0,
                0, 0, 0, 1]
    }
    static func rotationY(_ rad: Double) -> [Double] {
        let c = cos(rad), s = sin(rad)
        return [c, 0, -s, 0,
                0, 1, 0, 0,
                s, 0, c, 0,
                0, 0, 0, 1]
    }
    static func rotationZ(_ rad: Double) -> [Double] {
        let c = cos(rad), s = sin(rad)
        return [c, s, 0, 0,
                -s, c, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1]
    }
}

public extension TRS {
    private static let deg2rad = Double.pi / 180

    /// Composes to a USD row-major `matrix4d`: scale, then rotate (X→Y→Z),
    /// then translate (`M = S · Rx · Ry · Rz · T`).
    func toMatrix() -> [Double] {
        let s = Matrix4.scale(scale)
        let rx = Matrix4.rotationX(rotationEulerDegrees[0] * Self.deg2rad)
        let ry = Matrix4.rotationY(rotationEulerDegrees[1] * Self.deg2rad)
        let rz = Matrix4.rotationZ(rotationEulerDegrees[2] * Self.deg2rad)
        let t = Matrix4.translation(translation)
        return Matrix4.multiply(Matrix4.multiply(Matrix4.multiply(Matrix4.multiply(s, rx), ry), rz), t)
    }

    /// Decomposes a row-major `matrix4d` back into TRS. Assumes no shear;
    /// negative determinant flips `scale.x` so rotation stays proper.
    static func from(matrix m: [Double]) -> TRS {
        guard m.count == 16 else { return .identity }
        let translation = [m[12], m[13], m[14]]

        // Row vectors carry the basis; their lengths are the scale factors.
        func rowLen(_ r: Int) -> Double {
            (m[r*4] * m[r*4] + m[r*4+1] * m[r*4+1] + m[r*4+2] * m[r*4+2]).squareRoot()
        }
        var sx = rowLen(0), sy = rowLen(1), sz = rowLen(2)

        // Determinant of the upper-left 3×3; if negative, flip one axis.
        let det =
            m[0] * (m[5] * m[10] - m[6] * m[9]) -
            m[1] * (m[4] * m[10] - m[6] * m[8]) +
            m[2] * (m[4] * m[9] - m[5] * m[8])
        if det < 0 { sx = -sx }

        let r00 = m[0] / sx, r01 = m[1] / sx, r02 = m[2] / sx
        let r12 = m[6] / sy
        let r22 = m[10] / sz
        _ = r01

        // Extract XYZ Euler from the normalized rotation (row-vector form).
        let ry = asin(max(-1, min(1, -r02)))
        let rx: Double, rz: Double
        if abs(r02) < 0.999999 {
            rx = atan2(r12, r22)
            rz = atan2(r01, r00)
        } else {
            // Gimbal lock: fold rz into rx.
            rx = atan2(-m[9] / sy, m[5] / sy)
            rz = 0
        }
        let rad2deg = 180 / Double.pi
        return TRS(translation: translation,
                   rotationEulerDegrees: [rx * rad2deg, ry * rad2deg, rz * rad2deg],
                   scale: [sx, sy, sz])
    }
}

/// Gizmo axis-lock / snap increments shared by the viewport gizmo and the
/// numeric inspector fields.
public struct SnapSettings: Hashable, Sendable {
    /// Translation grid step in scene units; `nil` disables snapping.
    public var translation: Double?
    /// Rotation step in degrees; `nil` disables snapping.
    public var rotationDegrees: Double?
    /// Scale step; `nil` disables snapping.
    public var scale: Double?

    public init(translation: Double? = nil, rotationDegrees: Double? = nil, scale: Double? = nil) {
        self.translation = translation
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }

    public static let off = SnapSettings()

    static func snap(_ value: Double, to step: Double?) -> Double {
        guard let step, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    /// Applies the configured snapping to a candidate TRS.
    public func apply(to trs: TRS) -> TRS {
        TRS(translation: trs.translation.map { Self.snap($0, to: translation) },
            rotationEulerDegrees: trs.rotationEulerDegrees.map { Self.snap($0, to: rotationDegrees) },
            scale: trs.scale.map { Self.snap($0, to: scale) })
    }
}
