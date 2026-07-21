import Foundation

/// The kind of rigid articulation a joint realizes.
///
/// This is *rigid-body* articulation — a whole sub-assembly pivots or slides as
/// one solid piece about a mechanical axis (a lid, a door, a drawer). It is the
/// mechanical counterpart to skeletal rigging (RigKit), which deforms a skinned
/// mesh. A joint here never deforms geometry; it moves it rigidly.
public enum JointKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// A hinge: rotation about `axis` through `pivot`. `value` is degrees.
    case revolute
    /// A slider: translation along `axis`. `value` is scene units.
    case prismatic
}

/// A named articulation pose. `value` is interpreted per `JointKind`
/// (degrees for `.revolute`, scene units for `.prismatic`).
///
/// Every joint declares at least a `closed` (value 0, the rest pose) and an
/// `open` state so downstream tooling and export profiles have discrete,
/// portable positions to author.
public struct JointState: Codable, Sendable, Equatable {
    /// USD-identifier-safe, unique within the joint (e.g. "closed", "open").
    public var name: String
    public var value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}

/// A single rigid joint: how one component (`target`) moves relative to its
/// parent about a fixed axis. Pure value data — the pivot geometry and USD
/// authoring live in the authoring layer (`PivotMath` + the editor commands);
/// this type only *describes* the mechanism.
///
/// `pivot` is a point on the hinge/slide line, expressed in the assembly root's
/// local frame — this is the piece missing everywhere else in the stack, and
/// the reason a lid can hinge about its rear edge rather than its centre.
public struct Joint: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// USD-identifier-safe, unique within the assembly.
    public var name: String
    public var kind: JointKind
    /// Name of the moving component (a `ComponentNode` / prim name).
    public var target: String
    /// Local hinge/slide axis. Need not be unit length; normalized on use.
    public var axis: [Double]
    /// A point on the hinge/slide line, in the assembly-root local frame.
    public var pivot: [Double]
    /// Lower limit (degrees or units); `minValue <= maxValue`.
    public var minValue: Double
    /// Upper limit (degrees or units).
    public var maxValue: Double
    /// Named poses; must include `closed` and `open`, each within `[min, max]`.
    public var states: [JointState]
    /// The state the object loads in (must name one of `states`).
    public var defaultState: String

    public init(
        name: String, kind: JointKind, target: String,
        axis: [Double], pivot: [Double],
        minValue: Double, maxValue: Double,
        states: [JointState], defaultState: String
    ) {
        self.name = name
        self.kind = kind
        self.target = target
        self.axis = axis
        self.pivot = pivot
        self.minValue = minValue
        self.maxValue = maxValue
        self.states = states
        self.defaultState = defaultState
    }

    /// The canonical closed/open convenience constructor: a hinge or slider with
    /// exactly two states, closed at 0 and open at `openValue`, loading closed.
    public static func openable(
        name: String, kind: JointKind, target: String,
        axis: [Double], pivot: [Double], openValue: Double
    ) -> Joint {
        let lower = Swift.min(0, openValue)
        let upper = Swift.max(0, openValue)
        return Joint(
            name: name, kind: kind, target: target, axis: axis, pivot: pivot,
            minValue: lower, maxValue: upper,
            states: [JointState(name: "closed", value: 0),
                     JointState(name: "open", value: openValue)],
            defaultState: "closed")
    }

    /// The value for a named state, or nil if the state is not declared.
    public func value(ofState name: String) -> Double? {
        states.first { $0.name == name }?.value
    }
}
