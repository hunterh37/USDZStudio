import Foundation
import simd

/// Pure transform math for the pivot-Xform authoring pattern.
///
/// A joint is realized by inserting a dedicated pivot `Xform` between the moving
/// part and its parent, with the pivot Xform's origin placed *on the hinge/slide
/// line*. Rotating (or translating) that pivot Xform about its own origin then
/// moves the child about the correct axis — using only the single-matrix
/// authoring the stack already supports, with no off-origin pivot op-order.
///
/// Convention: matrices are column-vector (`p' = M · [x y z 1]ᵀ`), the standard
/// simd convention. The USD authoring layer transposes to row-major as needed.
public enum PivotMath {

    /// Normalize an axis vector; returns a unit vector. Falls back to +Y for a
    /// degenerate (near-zero) axis so callers never divide by zero — the
    /// invariant layer rejects degenerate axes separately, so this is only a
    /// safety net, not a silent correctness fudge.
    public static func normalizedAxis(_ axis: [Double]) -> SIMD3<Double> {
        let v = simd3(axis)
        let len = simd_length(v)
        guard len > epsilon else { return SIMD3<Double>(0, 1, 0) }
        return v / len
    }

    /// A pure translation matrix.
    public static func translation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4<Double>(t.x, t.y, t.z, 1)
        return m
    }

    /// Rotation by `degrees` about a (not-necessarily-unit) `axis`, via
    /// Rodrigues' rotation formula. About the world/local origin.
    public static func rotation(axis: [Double], degrees: Double) -> simd_double4x4 {
        let a = normalizedAxis(axis)
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r), t = 1 - c
        let x = a.x, y = a.y, z = a.z
        // Column-major 3x3 rotation (columns are the images of the basis vectors).
        let col0 = SIMD4<Double>(t*x*x + c,     t*x*y + s*z,   t*x*z - s*y, 0)
        let col1 = SIMD4<Double>(t*x*y - s*z,   t*y*y + c,     t*y*z + s*x, 0)
        let col2 = SIMD4<Double>(t*x*z + s*y,   t*y*z - s*x,   t*z*z + c,   0)
        let col3 = SIMD4<Double>(0, 0, 0, 1)
        return simd_double4x4(columns: (col0, col1, col2, col3))
    }

    /// The pivot Xform's local matrix for a joint at a given value
    /// (degrees for `.revolute`, units for `.prismatic`).
    ///
    /// - revolute:  `T(pivot) · R(axis, value)` — origin on the hinge line, so
    ///   the child rotates about `pivot`.
    /// - prismatic: `T(pivot + value · axiŝ)` — the pivot Xform slides along the axis.
    ///
    /// At `value == 0` both reduce to `T(pivot)`, the rest pose.
    public static func pivotLocalMatrix(_ joint: Joint, value: Double) -> simd_double4x4 {
        let pivot = simd3(joint.pivot)
        switch joint.kind {
        case .revolute:
            return translation(pivot) * rotation(axis: joint.axis, degrees: value)
        case .prismatic:
            return translation(pivot + normalizedAxis(joint.axis) * value)
        }
    }

    /// The one-time re-parent matrix applied to the moving child when the pivot
    /// Xform is inserted: `T(-pivot) · childLocal`. Combined with the rest pivot
    /// matrix `T(pivot)` it reproduces `childLocal` exactly, so inserting the
    /// pivot never moves the geometry (the closed pose is in place).
    public static func childReparentMatrix(_ joint: Joint,
                                           childLocal: simd_double4x4) -> simd_double4x4 {
        translation(-simd3(joint.pivot)) * childLocal
    }

    /// The full assembly-frame transform of the moving child at a value:
    /// `pivotLocalMatrix(value) · childReparentMatrix(childLocal)`. Equals
    /// `childLocal` at value 0.
    public static func childWorldMatrix(_ joint: Joint, value: Double,
                                        childLocal: simd_double4x4) -> simd_double4x4 {
        pivotLocalMatrix(joint, value: value) * childReparentMatrix(joint, childLocal: childLocal)
    }

    /// USD authoring helper: the 16 components of `m` in USD's row-major order
    /// (row 0 first), suitable for a `matrix4d` `xformOp:transform` value.
    public static func usdRowMajor(_ m: simd_double4x4) -> [Double] {
        // simd is column-major; USD `matrix4d` is row-major with a row-vector
        // convention, i.e. the transpose of our column-vector matrix.
        let t = m.transpose
        return (0..<4).flatMap { r in (0..<4).map { c in t[c][r] } }
    }

    /// Inverse of `usdRowMajor`: read a USD row-major (row-vector) `matrix4d`
    /// value back into our column-vector matrix. A 16-element input is required;
    /// a wrong-length input yields identity (the invariant/command layer rejects
    /// malformed matrices separately).
    public static func fromUsdRowMajor(_ a: [Double]) -> simd_double4x4 {
        guard a.count == 16 else { return matrix_identity_double4x4 }
        // Column j of the column-vector matrix is row j of the row-major data.
        func col(_ j: Int) -> SIMD4<Double> { SIMD4<Double>(a[j*4+0], a[j*4+1], a[j*4+2], a[j*4+3]) }
        return simd_double4x4(columns: (col(0), col(1), col(2), col(3)))
    }

    // MARK: - Row-major authoring API (EditingKit never touches simd)

    /// The pivot Xform's `xformOp:transform` value (USD row-major) for a joint
    /// at a given value. At value 0 this is the rest pose, `T(pivot)`.
    public static func pivotTransformRowMajor(_ joint: Joint, value: Double) -> [Double] {
        usdRowMajor(pivotLocalMatrix(joint, value: value))
    }

    /// The pivot transform for a named state, or nil if the state is undeclared.
    public static func pivotTransformRowMajor(_ joint: Joint, state: String) -> [Double]? {
        joint.value(ofState: state).map { pivotTransformRowMajor(joint, value: $0) }
    }

    /// The moving child's re-parent `xformOp:transform` value (USD row-major),
    /// given its current local transform (USD row-major). Combined with the rest
    /// pivot transform it reproduces the child's original placement exactly.
    public static func childReparentRowMajor(_ joint: Joint,
                                             childLocalRowMajor: [Double]) -> [Double] {
        let childLocal = fromUsdRowMajor(childLocalRowMajor)
        return usdRowMajor(childReparentMatrix(joint, childLocal: childLocal))
    }

    // MARK: - Internal helpers

    static let epsilon = 1e-9

    static func simd3(_ a: [Double]) -> SIMD3<Double> {
        // Callers pass validated [x, y, z]; pad defensively for the safety net.
        SIMD3<Double>(a.count > 0 ? a[0] : 0,
                      a.count > 1 ? a[1] : 0,
                      a.count > 2 ? a[2] : 0)
    }
}
