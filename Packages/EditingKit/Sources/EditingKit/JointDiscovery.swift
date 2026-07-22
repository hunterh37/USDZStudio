import Foundation
import USDCore
import MechanismKit

/// A rigid articulation found on a live stage, projected into exactly the
/// primitives the inspector's state switcher needs — pivot path, human labels,
/// the declared states, and the joint's *current* pose (which state it is in and
/// the raw value driving it).
///
/// This is a UI-facing projection on purpose: it exposes no `MechanismKit.Joint`,
/// so `EditorUI` can render and drive articulations through `EditingKit` alone,
/// without taking a dependency on `MechanismKit` (per the module layering).
public struct DiscoveredJoint: Sendable, Equatable, Identifiable {
    /// The pivot `Xform` carrying the `mechanism:joint` attribute — the prim a
    /// `SetJointStateCommand` re-authors and the natural selection target.
    public let pivotPath: PrimPath
    /// The joint's authored name (stable id within the assembly).
    public let name: String
    /// True for a hinge (revolute), false for a slider (prismatic).
    public let isRevolute: Bool
    /// Declared state names in authored order (e.g. ["closed", "open"]).
    public let stateNames: [String]
    /// The state the current pose matches within tolerance, or nil for an
    /// in-between pose (e.g. a hand-scrubbed angle).
    public let activeState: String?
    /// The raw value currently driving the pivot (degrees for a hinge, scene
    /// units for a slider), for seeding a scrub control.
    public let currentValue: Double
    public let minValue: Double
    public let maxValue: Double

    public var id: String { pivotPath.description }
    /// "Hinge" / "Slider" — the kind label for the UI badge.
    public var kindLabel: String { isRevolute ? "Hinge" : "Slider" }
    /// Unit suffix for the current value ("°" for a hinge, "u" for a slider).
    public var unitSuffix: String { isRevolute ? "°" : "u" }

    /// The value of a named state, or nil if it is not one of this joint's states.
    public func value(ofState state: String) -> Double? { stateValues[state] }

    // Kept internal so callers drive states by name; the raw map is an impl detail.
    let stateValues: [String: Double]
}

/// Read-only discovery of the rigid articulations authored on a stage. Pure over
/// the stage snapshot: scans every prim for the `mechanism:joint` attribute,
/// decodes it, and computes the current pose via `PivotMath`'s inverse. No
/// mutation, no MechanismKit types leak past `DiscoveredJoint`.
public enum JointDiscovery {

    /// Tolerance (in the joint's native unit) within which a live pose is
    /// considered to *be* a named state rather than an in-between value. Loose
    /// enough to absorb float round-trip through save, tight enough that "open"
    /// and "closed" never alias.
    static let stateMatchTolerance = 1e-3

    /// Every articulation on the stage, in stable path order. Malformed or
    /// undecodable `mechanism:joint` attributes are skipped rather than surfaced.
    public static func joints(in stage: any USDStageProtocol) -> [DiscoveredJoint] {
        stage.allPrims()
            .sorted { $0.path.description < $1.path.description }
            .compactMap(discovered(on:))
    }

    /// Project a single prim into a `DiscoveredJoint`, or nil if it carries no
    /// (decodable) joint.
    static func discovered(on prim: Prim) -> DiscoveredJoint? {
        guard let attr = prim.attribute(named: jointAttributeName),
              case let .string(json) = attr.value,
              let joint = JointCoding.decode(json) else { return nil }

        let currentTransform = localTransformRowMajor(of: prim)
        let currentValue = PivotMath.value(fromPivotRowMajor: currentTransform, joint: joint)
        let active = joint.states.first { abs($0.value - currentValue) <= stateMatchTolerance }?.name

        return DiscoveredJoint(
            pivotPath: prim.path,
            name: joint.name,
            isRevolute: joint.kind == .revolute,
            stateNames: joint.states.map(\.name),
            activeState: active,
            currentValue: currentValue,
            minValue: joint.minValue,
            maxValue: joint.maxValue,
            stateValues: Dictionary(joint.states.map { ($0.name, $0.value) },
                                    uniquingKeysWith: { first, _ in first }))
    }

    /// The prim's local `xformOp:transform` (USD row-major), or identity when it
    /// authors none — mirrors the reader in `JointCommands`, but off a `Prim`.
    private static func localTransformRowMajor(of prim: Prim) -> [Double] {
        if let attr = prim.attribute(named: transformAttributeName),
           case let .matrix4(m) = attr.value, m.count == 16 {
            return m
        }
        return Matrix4.identity
    }
}
