import Foundation
import simd

/// A 3-component vector in rig space. `SIMD3<Double>` is `Sendable`/`Codable`/`Equatable`.
public typealias Vec3 = SIMD3<Double>

/// A unit quaternion, stored `(w, x, y, z)` to match the UsdSkel `quatf` element order.
///
/// A custom value type (rather than `simd_quatd`) so it is `Codable` and its element
/// order is fixed and machine-checkable against the USD wire format.
public struct Quat: Sendable, Equatable, Codable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    /// Rotation of `degrees` about `axis` (need not be normalized; a degenerate axis yields identity).
    public init(axis: Vec3, degrees: Double) {
        let len = simd_length(axis)
        guard len > Math.epsilon else { self = .identity; return }
        let unit = axis / len
        let half = (degrees * .pi / 180.0) / 2.0
        let s = sin(half)
        self.init(w: cos(half), x: unit.x * s, y: unit.y * s, z: unit.z * s)
    }

    /// Squared norm.
    public var lengthSquared: Double { w * w + x * x + y * y + z * z }
    public var length: Double { lengthSquared.squareRoot() }

    /// Unit-length copy; a zero quaternion normalizes to identity.
    public var normalized: Quat {
        let l = length
        guard l > Math.epsilon else { return .identity }
        return Quat(w: w / l, x: x / l, y: y / l, z: z / l)
    }

    /// Hamilton product `self * rhs` (apply `rhs` first, then `self`).
    public func multiplied(by rhs: Quat) -> Quat {
        Quat(
            w: w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z,
            x: w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y,
            y: w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x,
            z: w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w)
    }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    /// Rotate a vector by this (assumed unit) quaternion.
    public func act(_ v: Vec3) -> Vec3 {
        let q = simd_quatd(ix: x, iy: y, iz: z, r: w)
        return q.act(v)
    }

    /// The dot product, used for shortest-arc interpolation and equality-up-to-sign checks.
    public func dot(_ rhs: Quat) -> Double { w * rhs.w + x * rhs.x + y * rhs.y + z * rhs.z }

    /// Spherical linear interpolation along the shortest arc. `t` is not clamped by the caller's
    /// contract but values in `0...1` are the meaningful range.
    public func slerp(to target: Quat, t: Double) -> Quat {
        var end = target.normalized
        let start = normalized
        var cosine = start.dot(end)
        // Take the shortest path by flipping one quaternion if the dot is negative.
        if cosine < 0 {
            end = Quat(w: -end.w, x: -end.x, y: -end.y, z: -end.z)
            cosine = -cosine
        }
        // Nearly parallel → linear interpolation avoids a divide-by-near-zero.
        if cosine > 1.0 - 1e-9 {
            let r = Quat(w: start.w + (end.w - start.w) * t,
                         x: start.x + (end.x - start.x) * t,
                         y: start.y + (end.y - start.y) * t,
                         z: start.z + (end.z - start.z) * t)
            return r.normalized
        }
        let theta = acos(cosine)
        let sinTheta = sin(theta)
        let a = sin((1 - t) * theta) / sinTheta
        let b = sin(t * theta) / sinTheta
        return Quat(w: a * start.w + b * end.w,
                    x: a * start.x + b * end.x,
                    y: a * start.y + b * end.y,
                    z: a * start.z + b * end.z)
    }

    /// The 3×3 rotation embedded in a homogeneous 4×4 (column-major simd).
    public var matrix: simd_double4x4 {
        let q = simd_quatd(ix: x, iy: y, iz: z, r: w).normalized
        let m3 = simd_matrix3x3(q)
        return simd_double4x4(
            SIMD4<Double>(m3.columns.0, 0),
            SIMD4<Double>(m3.columns.1, 0),
            SIMD4<Double>(m3.columns.2, 0),
            SIMD4<Double>(0, 0, 0, 1))
    }

    /// Build a quaternion from a pure-rotation matrix (Shepperd's method), robust to numeric drift.
    public static func fromMatrix(_ m: simd_double4x4) -> Quat {
        let m00 = m.columns.0.x, m11 = m.columns.1.y, m22 = m.columns.2.z
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = (trace + 1.0).squareRoot() * 2.0
            return Quat(w: 0.25 * s,
                        x: (m.columns.1.z - m.columns.2.y) / s,
                        y: (m.columns.2.x - m.columns.0.z) / s,
                        z: (m.columns.0.y - m.columns.1.x) / s).normalized
        } else if m00 > m11 && m00 > m22 {
            let s = (1.0 + m00 - m11 - m22).squareRoot() * 2.0
            return Quat(w: (m.columns.1.z - m.columns.2.y) / s,
                        x: 0.25 * s,
                        y: (m.columns.1.x + m.columns.0.y) / s,
                        z: (m.columns.2.x + m.columns.0.z) / s).normalized
        } else if m11 > m22 {
            let s = (1.0 + m11 - m00 - m22).squareRoot() * 2.0
            return Quat(w: (m.columns.2.x - m.columns.0.z) / s,
                        x: (m.columns.1.x + m.columns.0.y) / s,
                        y: 0.25 * s,
                        z: (m.columns.2.y + m.columns.1.z) / s).normalized
        } else {
            let s = (1.0 + m22 - m00 - m11).squareRoot() * 2.0
            return Quat(w: (m.columns.0.y - m.columns.1.x) / s,
                        x: (m.columns.2.x + m.columns.0.z) / s,
                        y: (m.columns.2.y + m.columns.1.z) / s,
                        z: 0.25 * s).normalized
        }
    }
}

/// Shared numeric helpers and tolerances for the rig math (mirrors `MechanismKit.PivotMath`'s style).
public enum Math {
    public static let epsilon = 1e-12

    /// Translation matrix (column-major simd).
    public static func translation(_ t: Vec3) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4<Double>(t, 1)
        return m
    }

    /// Uniform/non-uniform scale matrix.
    public static func scale(_ s: Vec3) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4<Double>(s, 1))
    }

    /// Compose translate · rotate · scale (applied S, then R, then T to a point).
    public static func trs(translation t: Vec3, rotation r: Quat, scale s: Vec3) -> simd_double4x4 {
        translation(t) * r.matrix * scale(s)
    }

    /// The translation column of a 4×4.
    public static func origin(of m: simd_double4x4) -> Vec3 {
        Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Convert a column-major simd 4×4 to USD's row-major flat 16-array.
    public static func rowMajor(_ m: simd_double4x4) -> [Double] {
        var out = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 {
                out[r * 4 + c] = m[c][r]
            }
        }
        return out
    }

    /// Inverse of `rowMajor`. A wrong-length input yields identity (defensive, matches PivotMath).
    public static func fromRowMajor(_ a: [Double]) -> simd_double4x4 {
        guard a.count == 16 else { return matrix_identity_double4x4 }
        var m = matrix_identity_double4x4
        for r in 0..<4 {
            for c in 0..<4 {
                m[c][r] = a[r * 4 + c]
            }
        }
        return m
    }

    /// Maximum absolute component difference between two matrices — the residual used by invariants.
    public static func maxComponentDifference(_ a: simd_double4x4, _ b: simd_double4x4) -> Double {
        var worst = 0.0
        for c in 0..<4 {
            for r in 0..<4 {
                worst = Swift.max(worst, abs(a[c][r] - b[c][r]))
            }
        }
        return worst
    }

    /// A unit rotation carrying direction `from` onto direction `to` (shortest arc).
    /// Degenerate inputs (either near-zero, or already aligned) yield identity; anti-parallel
    /// inputs rotate 180° about an arbitrary perpendicular axis.
    public static func rotationBetween(_ from: Vec3, _ to: Vec3) -> Quat {
        let lf = simd_length(from), lt = simd_length(to)
        guard lf > epsilon, lt > epsilon else { return .identity }
        let a = from / lf, b = to / lt
        let cosine = simd_clamp(simd_dot(a, b), -1.0, 1.0)
        if cosine > 1.0 - 1e-15 { return .identity }
        if cosine < -1.0 + 1e-12 {
            // Anti-parallel: pick any axis orthogonal to `a`.
            var axis = simd_cross(a, Vec3(1, 0, 0))
            if simd_length(axis) < 1e-6 { axis = simd_cross(a, Vec3(0, 1, 0)) }
            return Quat(axis: axis, degrees: 180)
        }
        let axis = simd_cross(a, b)
        let angle = acos(cosine) * 180.0 / .pi
        return Quat(axis: axis, degrees: angle)
    }

    /// Extract the (normalized) rotation quaternion from a possibly-scaled world matrix.
    public static func rotation(of m: simd_double4x4) -> Quat {
        // Normalize the basis columns so non-uniform scale doesn't leak into the rotation.
        func col(_ i: Int) -> Vec3 {
            let c = m[i]
            let v = Vec3(c.x, c.y, c.z)
            let l = simd_length(v)
            return l > epsilon ? v / l : v
        }
        let r = simd_double4x4(
            SIMD4<Double>(col(0), 0),
            SIMD4<Double>(col(1), 0),
            SIMD4<Double>(col(2), 0),
            SIMD4<Double>(0, 0, 0, 1))
        return Quat.fromMatrix(r)
    }
}

/// Chain-solve helpers shared by the IK solvers.
public enum SolverSupport {
    /// Apply a world-space delta rotation `delta` at joint `j`, returning the updated pose.
    /// Only the joint's rotation channel changes; the pivot is the joint origin.
    public static func applyingWorldRotation(_ delta: Quat, at j: Int,
                                             pose: Pose, skeleton: Skeleton) -> Pose {
        let worlds = pose.worldMatrices(skeleton)
        let parentRot: Quat
        if let p = skeleton.joints[j].parent {
            parentRot = Math.rotation(of: worlds[p])
        } else {
            parentRot = .identity
        }
        let localRot = pose.locals[j].rotation
        // newLocal = parentRotᐟ · delta · parentRot · localRot
        let newLocal = parentRot.conjugate
            .multiplied(by: delta)
            .multiplied(by: parentRot)
            .multiplied(by: localRot)
            .normalized
        var t = pose.locals[j]
        t.rotation = newLocal
        return pose.setting(t, at: j)
    }
}
