import Foundation
import USDCore

/// The attribute name carrying a prim's local transform. The USDA serializer
/// synthesizes `xformOpOrder` from its presence, so authoring this alone is
/// sufficient.
public let transformAttributeName = "xformOp:transform"

public extension USDStageProtocol {
    /// The prim's local transform as a TRS, or `.identity` when it authors no
    /// `xformOp:transform`.
    func transform(at path: PrimPath) -> TRS {
        guard let attr = prim(at: path)?.attribute(named: transformAttributeName),
              case let .matrix4(m) = attr.value else {
            return .identity
        }
        return TRS.from(matrix: m)
    }

    /// The prim's world matrix: its local transform composed up the ancestor
    /// chain to the root (row-vector convention, `world = local · parentWorld`).
    /// The root layer's frame is identity.
    func worldMatrix(at path: PrimPath) -> [Double] {
        var m = Matrix4.identity
        var p = path
        while !p.isRoot {
            let local = prim(at: p) != nil ? transform(at: p).toMatrix() : Matrix4.identity
            m = Matrix4.multiply(m, local)
            p = p.parent
        }
        return m
    }
}

/// Authors a prim's local transform, capturing the prior attribute for undo.
///
/// A single drag (translate/rotate/scale) commits exactly one of these, so the
/// gesture appears as one Edit ▸ Undo entry regardless of how many intermediate
/// frames the gizmo pushed for live preview.
public struct SetTransformCommand: EditCommand {
    public let path: PrimPath
    public let newTRS: TRS
    /// The prior `xformOp:transform` attribute, or `nil` if the prim had none.
    public let oldAttribute: Attribute?
    /// Verb for the menu label ("Move", "Rotate", "Scale", or "Transform").
    public let verb: String
    private let name: String

    public init(path: PrimPath, newTRS: TRS, oldAttribute: Attribute?, verb: String = "Transform") {
        self.path = path
        self.newTRS = newTRS
        self.oldAttribute = oldAttribute
        self.verb = verb
        self.name = path.name
    }

    public var label: String { "\(verb) \(name)" }

    private var newAttribute: Attribute {
        Attribute(name: transformAttributeName, value: .matrix4(newTRS.toMatrix()))
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setAttribute(path: path, attribute: newAttribute))
    }

    public func undo(on stage: any USDStageMutable) throws {
        // No removeAttribute mutation yet (Phase 3): if the prim had no prior
        // transform, restore an identity op — semantically a no-op transform.
        let restore = oldAttribute
            ?? Attribute(name: transformAttributeName, value: .matrix4(Matrix4.identity))
        try stage.apply(.setAttribute(path: path, attribute: restore))
    }
}

/// A live gizmo/inspector drag against one prim.
///
/// `update(_:)` writes snapped transforms straight to the stage for immediate
/// viewport feedback but records nothing for undo. When the gesture ends,
/// `makeCommand()` yields a single `SetTransformCommand` (from the pre-drag
/// value to the final value) to run through the `CommandStack` — coalesced undo.
public final class TransformDragSession {
    private let stage: any USDStageMutable
    public let path: PrimPath
    public var snap: SnapSettings

    /// The prim's transform when the drag began.
    public let startTRS: TRS
    private let startAttribute: Attribute?
    /// The latest snapped transform written to the stage.
    public private(set) var currentTRS: TRS

    public init(stage: any USDStageMutable, path: PrimPath, snap: SnapSettings = .off) {
        self.stage = stage
        self.path = path
        self.snap = snap
        self.startAttribute = stage.prim(at: path)?.attribute(named: transformAttributeName)
        let start = stage.transform(at: path)
        self.startTRS = start
        self.currentTRS = start
    }

    /// Snaps `trs`, writes it to the stage for live preview, and remembers it.
    @discardableResult
    public func update(_ trs: TRS) throws -> TRS {
        let snapped = snap.apply(to: trs)
        currentTRS = snapped
        try stage.apply(.setAttribute(path: path,
                                      attribute: Attribute(name: transformAttributeName,
                                                           value: .matrix4(snapped.toMatrix()))))
        return snapped
    }

    /// Translate relative to the drag-start transform.
    @discardableResult
    public func translate(by delta: [Double]) throws -> TRS {
        var trs = startTRS
        trs.translation = zip(startTRS.translation, delta).map(+)
        return try update(trs)
    }

    /// Rotate (degrees, XYZ) relative to the drag-start transform.
    @discardableResult
    public func rotate(byDegrees delta: [Double]) throws -> TRS {
        var trs = startTRS
        trs.rotationEulerDegrees = zip(startTRS.rotationEulerDegrees, delta).map(+)
        return try update(trs)
    }

    /// Uniform scale multiplier relative to the drag-start transform.
    @discardableResult
    public func scale(by factor: Double) throws -> TRS {
        var trs = startTRS
        trs.scale = startTRS.scale.map { $0 * factor }
        return try update(trs)
    }

    /// Per-axis scale multipliers `[sx, sy, sz]` relative to the drag-start
    /// transform — the scale gizmo's per-axis box handles, where a `1` leaves
    /// that axis untouched.
    @discardableResult
    public func scale(byPerAxis factors: [Double]) throws -> TRS {
        var trs = startTRS
        trs.scale = zip(startTRS.scale, factors).map(*)
        return try update(trs)
    }

    /// Restores the stage to its pre-drag state (for an escaped/cancelled drag).
    public func cancel() throws {
        let restore = startAttribute
            ?? Attribute(name: transformAttributeName, value: .matrix4(startTRS.toMatrix()))
        try stage.apply(.setAttribute(path: path, attribute: restore))
        currentTRS = startTRS
    }

    /// The undoable command for the completed drag, or `nil` if nothing moved.
    /// The stage already reflects `currentTRS`, so run this through the stack to
    /// *record* the change (its execute is idempotent).
    public func makeCommand(verb: String = "Transform") -> SetTransformCommand? {
        guard currentTRS != startTRS else { return nil }
        return SetTransformCommand(path: path, newTRS: currentTRS,
                                   oldAttribute: startAttribute, verb: verb)
    }
}
