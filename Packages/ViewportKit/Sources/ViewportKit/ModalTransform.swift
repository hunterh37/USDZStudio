import Foundation

/// The Blender-style *modal* transform: a keyboard-initiated grab/rotate/scale
/// that starts immediately (no handle click) and follows the cursor, with
/// axis/plane constraints and typed numeric deltas. It is an alternative
/// *driver* onto the same math the W/E/R handle gizmos use — it produces a
/// proposed world-space op which the document folds into the shipped
/// `SetTransformCommand`/`TransformDragSession` coalesced-undo path.
///
/// Everything here is pure value-type math (no RealityKit/AppKit); the viewport
/// input layer starts/updates/commits a session and renders `hudText`.
/// Reuses `GizmoAxis`, `GizmoBasis`, `ExtrudeGizmoMath.axisParameter`, and
/// `RotateGizmoMath.signedAngleDegrees` — it does not fork that math.

public enum ModalTransformKind: Equatable, Sendable {
    case grab, rotate, scale

    /// The key that starts this modal transform (Blender idiom: G/R/S).
    public var shortcut: Character {
        switch self {
        case .grab: "g"
        case .rotate: "r"
        case .scale: "s"
        }
    }

    /// The mode a pressed key starts, or `nil` for any other key.
    public static func forShortcut(_ key: Character) -> ModalTransformKind? {
        let lowered = Character(key.lowercased())
        switch lowered {
        case "g": return .grab
        case "r": return .rotate
        case "s": return .scale
        default: return nil
        }
    }

    /// Undo-menu verb for the coalesced command this transform emits.
    public var undoVerb: String {
        switch self {
        case .grab: "Move"
        case .rotate: "Rotate"
        case .scale: "Scale"
        }
    }
}

/// Axis/plane constraint accumulated during a modal session.
public enum ModalConstraint: Equatable, Sendable {
    /// Follows the cursor in the view plane (grab) / screen (rotate, scale).
    case free
    /// Locked to one axis (X/Y/Z). `local` uses the selection's own basis.
    case axis(GizmoAxis, local: Bool)
    /// Locked to the plane whose normal is the given axis (Shift+axis).
    case plane(GizmoAxis, local: Bool)
}

/// Typed numeric entry ("2.4", "-3", ".5"); overrides the pointer magnitude
/// when non-empty. Grammar: digits, at most one '.', a leading '-' only.
public struct NumericEntry: Equatable, Sendable {
    public private(set) var text: String

    public init(text: String = "") { self.text = text }

    public static let empty = NumericEntry(text: "")

    public var isEmpty: Bool { text.isEmpty }

    /// The parsed value, or `nil` for an empty or partial buffer ("", "-", ".").
    public var value: Double? { Double(text) }

    /// Appends `c` if it keeps the buffer a valid partial number, else no-op.
    /// Accepts `0…9` anywhere, a single `.`, and a `-` only as the first char.
    public mutating func append(_ c: Character) {
        if c.isNumber {
            text.append(c)
        } else if c == "." {
            if !text.contains(".") { text.append(c) }
        } else if c == "-" {
            if text.isEmpty { text.append(c) }
        }
    }

    /// Removes the last character (no-op when empty).
    public mutating func backspace() {
        if !text.isEmpty { text.removeLast() }
    }
}

/// The proposed world-space op a modal session produces from one pointer/numeric
/// sample. The document turns it into a matrix applied about the pivot and folds
/// it into one coalesced `SetTransformCommand`.
public enum ModalOp: Equatable, Sendable {
    /// World-space translation delta.
    case translate(SIMD3<Double>)
    /// Rotation about `axis` (unit world direction) by `degrees` (right-hand).
    case rotate(axis: SIMD3<Double>, degrees: Double)
    /// Per-axis scale factors expressed in `basis` (a `1` leaves that axis).
    case scale(basis: GizmoBasis, factors: SIMD3<Double>)

    /// The identity (no-change) op for this kind — what a cancelled or
    /// zero-magnitude session proposes.
    public static func identity(for kind: ModalTransformKind) -> ModalOp {
        switch kind {
        case .grab: .translate(.zero)
        case .rotate: .rotate(axis: SIMD3(0, 0, 1), degrees: 0)
        case .scale: .scale(basis: .world, factors: SIMD3(1, 1, 1))
        }
    }
}

/// The modal transform state machine. Seeded from the selection's world pivot
/// and local basis; every input returns a *proposed* `ModalOp` the viewport
/// previews live. Cancel discards it; confirm emits one command.
public struct ModalTransform: Equatable, Sendable {
    public let kind: ModalTransformKind
    /// World-space pivot (median for multi-select).
    public let pivot: SIMD3<Double>
    /// The selection's local basis, for local-axis constraints.
    public let basis: GizmoBasis
    public private(set) var constraint: ModalConstraint
    public private(set) var numeric: NumericEntry
    /// The last explicitly chosen axis — the default axis for numeric entry
    /// while unconstrained (matches Blender's "type a number after G").
    public private(set) var lastAxis: GizmoAxis?

    public init(kind: ModalTransformKind, pivot: SIMD3<Double>, basis: GizmoBasis = .world,
                constraint: ModalConstraint = .free, numeric: NumericEntry = .empty) {
        self.kind = kind
        self.pivot = pivot
        self.basis = basis
        self.constraint = constraint
        self.numeric = numeric
        if case let .axis(a, _) = constraint { lastAxis = a }
        if case let .plane(a, _) = constraint { lastAxis = a }
    }

    // MARK: Inputs (pure mutators)

    /// X/Y/Z pressed. `shift` requests a plane lock. Pressing the same axis with
    /// the same plane-ness again toggles the world↔local basis (Blender's
    /// `XX`); any other press sets a fresh world-basis constraint.
    public mutating func setConstraint(axis: GizmoAxis, shift: Bool) {
        lastAxis = axis
        switch constraint {
        case let .axis(a, local) where !shift && a == axis:
            constraint = .axis(axis, local: !local)   // repeat toggles local
        case let .plane(a, local) where shift && a == axis:
            constraint = .plane(axis, local: !local)
        default:
            constraint = shift ? .plane(axis, local: false) : .axis(axis, local: false)
        }
    }

    public mutating func typeDigit(_ c: Character) { numeric.append(c) }

    public mutating func backspaceNumeric() { numeric.backspace() }

    // MARK: Proposed op

    /// The proposed op from a pointer sample. `pointer`/`start`/`pivotScreen`
    /// are screen-space (rotate/scale measure angle/radius there); `startRay`/
    /// `currentRay` supply the world projection for grab and axis-constrained
    /// rotate (same rays the handle gizmos use).
    public func proposedOp(pointer: CGPoint, start: CGPoint, pivotScreen: CGPoint,
                           startRay: CameraRay.Ray, currentRay: CameraRay.Ray) -> ModalOp {
        switch kind {
        case .grab: proposedGrab(pointer: pointer, start: start,
                                 startRay: startRay, currentRay: currentRay)
        case .rotate: proposedRotate(pointer: pointer, start: start, pivotScreen: pivotScreen,
                                     startRay: startRay, currentRay: currentRay)
        case .scale: proposedScale(pointer: pointer, start: start, pivotScreen: pivotScreen)
        }
    }

    // MARK: Grab

    private func proposedGrab(pointer: CGPoint, start: CGPoint,
                              startRay: CameraRay.Ray, currentRay: CameraRay.Ray) -> ModalOp {
        // Numeric override: a signed distance along the active axis.
        if let v = numeric.value {
            let dir = Self.axisDirection(numericAxis, basis: basis, local: numericLocal)
            return .translate(dir * v)
        }
        switch constraint {
        case .free:
            return .translate(freeDelta(startRay: startRay, currentRay: currentRay))
        case let .axis(a, local):
            let dir = Self.axisDirection(a, basis: basis, local: local)
            let t0 = ExtrudeGizmoMath.axisParameter(ray: startRay, origin: pivot, axis: dir)
            let t1 = ExtrudeGizmoMath.axisParameter(ray: currentRay, origin: pivot, axis: dir)
            guard let t0, let t1 else { return .translate(.zero) }
            return .translate(dir * (t1 - t0))
        case let .plane(a, local):
            let n = Self.axisDirection(a, basis: basis, local: local)
            let d = freeDelta(startRay: startRay, currentRay: currentRay)
            return .translate(d - n * Self.dot(d, n))   // drop the normal component
        }
    }

    /// Free (view-plane) translation delta: unproject both rays onto the plane
    /// through the pivot facing the camera and difference the hits.
    private func freeDelta(startRay: CameraRay.Ray, currentRay: CameraRay.Ray) -> SIMD3<Double> {
        let normal = Self.normalize(startRay.origin - pivot)   // toward the camera
        guard let a = Self.planeHit(ray: startRay, origin: pivot, normal: normal),
              let b = Self.planeHit(ray: currentRay, origin: pivot, normal: normal)
        else { return .zero }
        return b - a
    }

    // MARK: Rotate

    private func proposedRotate(pointer: CGPoint, start: CGPoint, pivotScreen: CGPoint,
                                startRay: CameraRay.Ray, currentRay: CameraRay.Ray) -> ModalOp {
        let axisDir = rotationAxis(startRay: startRay)
        if let v = numeric.value {          // typed degrees
            return .rotate(axis: axisDir, degrees: v)
        }
        let degrees = RotateGizmoMath.signedAngleDegrees(
            from: startRay, to: currentRay, origin: pivot, axis: axisDir) ?? 0
        return .rotate(axis: axisDir, degrees: degrees)
    }

    /// The world rotation axis: the constrained axis, or the view direction
    /// (camera → pivot) when unconstrained (screen rotation).
    private func rotationAxis(startRay: CameraRay.Ray) -> SIMD3<Double> {
        switch constraint {
        case .free:
            return Self.normalize(pivot - startRay.origin)
        case let .axis(a, local), let .plane(a, local):
            return Self.axisDirection(a, basis: basis, local: local)
        }
    }

    // MARK: Scale

    private func proposedScale(pointer: CGPoint, start: CGPoint, pivotScreen: CGPoint) -> ModalOp {
        let factor: Double
        if let v = numeric.value {
            factor = v                       // typed factor (1 = identity)
        } else {
            let d0 = Self.screenDistance(start, pivotScreen)
            let d1 = Self.screenDistance(pointer, pivotScreen)
            factor = d0 > 1e-6 ? d1 / d0 : 1
        }
        switch constraint {
        case .free:
            return .scale(basis: .world, factors: SIMD3(factor, factor, factor))
        case let .axis(a, local):
            var f = SIMD3(1.0, 1.0, 1.0)
            f[a.rawValue] = factor
            return .scale(basis: local ? basis : .world, factors: f)
        case let .plane(a, local):
            // Scale the two in-plane axes; leave the normal axis unchanged.
            var f = SIMD3(factor, factor, factor)
            f[a.rawValue] = 1
            return .scale(basis: local ? basis : .world, factors: f)
        }
    }

    // MARK: Numeric-axis resolution

    /// The axis a typed number applies along: the constrained axis, else the
    /// last explicitly chosen axis, else X (Blender's default).
    private var numericAxis: GizmoAxis {
        switch constraint {
        case let .axis(a, _), let .plane(a, _): a
        case .free: lastAxis ?? .x
        }
    }

    private var numericLocal: Bool {
        switch constraint {
        case let .axis(_, local), let .plane(_, local): local
        case .free: false
        }
    }

    // MARK: HUD

    /// The status line the viewport renders, e.g. "Move Z: 2.4 (global)".
    public var hudText: String {
        var s = kind.undoVerb
        switch constraint {
        case .free:
            break
        case let .axis(a, local):
            s += " \(Self.axisLabel(a))"
            if !numeric.isEmpty { s += ": \(numeric.text)" }
            s += local ? " (local)" : " (global)"
            return s
        case let .plane(a, local):
            s += " plane \(Self.planeLabel(a))"
            if !numeric.isEmpty { s += ": \(numeric.text)" }
            s += local ? " (local)" : " (global)"
            return s
        }
        if !numeric.isEmpty { s += ": \(numeric.text)" }
        return s
    }

    private static func axisLabel(_ a: GizmoAxis) -> String {
        switch a { case .x: "X"; case .y: "Y"; case .z: "Z" }
    }

    /// The two-letter name of the plane whose normal is `a` (⊥Z → "XY").
    private static func planeLabel(_ a: GizmoAxis) -> String {
        switch a { case .x: "YZ"; case .y: "XZ"; case .z: "XY" }
    }

    // MARK: Pure geometry helpers (kept local so the file is self-contained)

    /// The unit world direction of `axis` in the chosen basis.
    static func axisDirection(_ axis: GizmoAxis, basis: GizmoBasis, local: Bool) -> SIMD3<Double> {
        normalize((local ? basis : .world).direction(axis))
    }

    /// World point where `ray` crosses the plane through `origin` with `normal`,
    /// or `nil` when parallel / behind the ray.
    static func planeHit(ray: CameraRay.Ray, origin: SIMD3<Double>,
                         normal: SIMD3<Double>) -> SIMD3<Double>? {
        let denom = dot(normal, ray.direction)
        guard abs(denom) > 1e-9 else { return nil }
        let t = dot(normal, origin - ray.origin) / denom
        guard t >= 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    static func screenDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = dot(v, v).squareRoot()
        return l > 1e-12 ? v / l : v
    }
}
