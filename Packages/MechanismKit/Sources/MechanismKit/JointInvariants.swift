import Foundation
import simd

/// A schema/consistency problem found on a `Joint`.
public struct JointIssue: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable { case error, warning }
    public var severity: Severity
    public var message: String
    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Pure validation + machine-checkable invariants for rigid joints. Correctness
/// here is provable without a human eyeball (the MeshKit discipline): the
/// geometric invariants below are exact predicates the test corpus fuzzes.
public enum JointInvariants {

    /// A USD-identifier-safe token: starts with a letter or `_`, then letters,
    /// digits, or `_`. Self-contained (MechanismKit is a zero-dependency leaf).
    public static func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        return s.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Schema/consistency issues on a joint. Error-severity issues block
    /// authoring; warnings are advisory.
    public static func validate(_ joint: Joint) -> [JointIssue] {
        var issues: [JointIssue] = []

        if !isValidIdentifier(joint.name) {
            issues.append(.init(.error, "joint name '\(joint.name)' is not a valid USD identifier"))
        }
        if !isValidIdentifier(joint.target) {
            issues.append(.init(.error, "joint '\(joint.name)' target '\(joint.target)' is not a valid USD identifier"))
        }
        if joint.axis.count != 3 {
            issues.append(.init(.error, "joint '\(joint.name)' axis must be [x, y, z]"))
        } else if simd_length(PivotMath.simd3(joint.axis)) <= PivotMath.epsilon {
            issues.append(.init(.error, "joint '\(joint.name)' axis is degenerate (near-zero length)"))
        }
        if joint.pivot.count != 3 {
            issues.append(.init(.error, "joint '\(joint.name)' pivot must be [x, y, z]"))
        }
        if joint.minValue > joint.maxValue {
            issues.append(.init(.error, "joint '\(joint.name)' minValue \(joint.minValue) exceeds maxValue \(joint.maxValue)"))
        }

        // States: non-empty, unique names, valid identifiers, in range,
        // closed+open present, and default resolvable.
        if joint.states.isEmpty {
            issues.append(.init(.error, "joint '\(joint.name)' declares no states"))
        }
        var seen = Set<String>()
        for state in joint.states {
            if !isValidIdentifier(state.name) {
                issues.append(.init(.error, "joint '\(joint.name)' state name '\(state.name)' is not a valid USD identifier"))
            }
            if !seen.insert(state.name).inserted {
                issues.append(.init(.error, "joint '\(joint.name)' has duplicate state '\(state.name)'"))
            }
            if joint.minValue <= joint.maxValue,
               state.value < joint.minValue || state.value > joint.maxValue {
                issues.append(.init(.error, "joint '\(joint.name)' state '\(state.name)' value \(state.value) is outside limits [\(joint.minValue), \(joint.maxValue)]"))
            }
        }
        for required in ["closed", "open"] where !seen.contains(required) {
            issues.append(.init(.error, "joint '\(joint.name)' is missing the required '\(required)' state"))
        }
        if !seen.contains(joint.defaultState) {
            issues.append(.init(.error, "joint '\(joint.name)' defaultState '\(joint.defaultState)' names no declared state"))
        }

        return issues
    }

    /// True when the joint has no error-severity issues.
    public static func isValid(_ joint: Joint) -> Bool {
        !validate(joint).contains { $0.severity == .error }
    }

    // MARK: - Geometric invariants (exact predicates, fuzzed by the test corpus)

    /// **Axis fixed-point.** Every point on the hinge line is invariant under a
    /// revolute pose. This is *the* correctness test for "rotates about the
    /// right axis" — returns the largest displacement of a set of on-axis sample
    /// points; a correct hinge keeps it within `tolerance`.
    public static func axisFixedPointResidual(_ joint: Joint, degrees: Double) -> Double {
        let pivot = PivotMath.simd3(joint.pivot)
        let axis = PivotMath.normalizedAxis(joint.axis)
        // The rotation-about-the-hinge-line operator on assembly-frame points is
        // T(pivot)·R·T(-pivot). (In authoring, the T(-pivot) comes from the child
        // re-parent matrix; here we compose the full operator to test the line.)
        let m = PivotMath.translation(pivot)
            * PivotMath.rotation(axis: joint.axis, degrees: degrees)
            * PivotMath.translation(-pivot)
        var worst = 0.0
        for t in [-3.0, -0.5, 0, 1.0, 7.5] {
            let q = pivot + axis * t
            let moved = m * SIMD4<Double>(q.x, q.y, q.z, 1)
            worst = Swift.max(worst, simd_distance(SIMD3<Double>(moved.x, moved.y, moved.z), q))
        }
        return worst
    }

    /// **Rest == closed.** The pivot matrix at value 0 is a pure translation by
    /// `pivot` (identity rotation/scale); returns how far from that it is.
    public static func restResidual(_ joint: Joint) -> Double {
        let rest = PivotMath.pivotLocalMatrix(joint, value: 0)
        let expected = PivotMath.translation(PivotMath.simd3(joint.pivot))
        return maxComponentDifference(rest, expected)
    }

    /// **Geometry-in-place.** Inserting the pivot Xform must not move the child:
    /// the child's assembly-frame transform at value 0 equals its original local
    /// transform. Returns the residual.
    public static func geometryInPlaceResidual(_ joint: Joint,
                                               childLocal: simd_double4x4) -> Double {
        let composed = PivotMath.childWorldMatrix(joint, value: 0, childLocal: childLocal)
        return maxComponentDifference(composed, childLocal)
    }

    /// **Prismatic displacement.** A slider moves the child by exactly `value`
    /// along the unit axis; returns the error in that displacement magnitude.
    public static func prismaticDisplacementError(_ joint: Joint, value: Double,
                                                  childLocal: simd_double4x4) -> Double {
        let rest = PivotMath.childWorldMatrix(joint, value: 0, childLocal: childLocal).columns.3
        let moved = PivotMath.childWorldMatrix(joint, value: value, childLocal: childLocal).columns.3
        let delta = SIMD3<Double>(moved.x - rest.x, moved.y - rest.y, moved.z - rest.z)
        return abs(simd_length(delta) - abs(value))
    }

    static func maxComponentDifference(_ a: simd_double4x4, _ b: simd_double4x4) -> Double {
        var worst = 0.0
        for c in 0..<4 {
            let d = a[c] - b[c]   // simd_double4x4 supports column subscript directly
            worst = Swift.max(worst, abs(d.x), abs(d.y), abs(d.z), abs(d.w))
        }
        return worst
    }
}
