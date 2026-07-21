import Foundation
import USDCore
import MechanismKit

/// The custom attribute that marks a pivot `Xform` as a rigid articulation and
/// carries its `Joint` description (JSON). Authored as `uniform string` so it is
/// a stable, round-trippable part of the stage and discoverable by runtime
/// tooling and the export-compliance layer (specs/articulation-mechanisms.md).
public let jointAttributeName = "mechanism:joint"

/// Encode/decode a `Joint` to the deterministic JSON stored in
/// `mechanism:joint`. Sorted keys keep `open → save → open` byte-stable.
public enum JointCoding {
    public static func encode(_ joint: Joint) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a value type with only finite scalars cannot fail; the empty
        // fallback keeps the API non-throwing for call sites.
        guard let data = try? encoder.encode(joint) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> Joint? {
        try? JSONDecoder().decode(Joint.self, from: Data(json.utf8))
    }
}

/// Reads a prim's local `xformOp:transform` as a USD row-major matrix, or the
/// identity when the prim authors none.
func localTransformRowMajor(of path: PrimPath, in stage: any USDStageProtocol) -> [Double] {
    if let attr = stage.prim(at: path)?.attribute(named: transformAttributeName),
       case let .matrix4(m) = attr.value, m.count == 16 {
        return m
    }
    return Matrix4.identity
}

/// **Create a rigid joint** on a part — makes it open / close / swing about a
/// fixed axis (a lid, door, cap, drawer), PRD §5.3 "open the door — proper
/// Xform ops on that prim".
///
/// It inserts a dedicated pivot `Xform` between the moving part and its parent,
/// with the pivot's origin on the hinge/slide line, and adjusts the part's local
/// transform so inserting the pivot does not move it (the closed pose is exactly
/// where the part already was). The pivot carries the `Joint` description so the
/// state can later be driven by `SetJointStateCommand`, the export profile can
/// flag it, and runtime tooling can discover it.
///
/// `axis` and `pivot` are expressed in the moving part's **parent local space**
/// (the same space the part's own transform lives in), so the math is exact and
/// local.
public struct CreateJointCommand: EditCommand {
    /// The moving part as it was before the joint (for undo).
    public let original: Prim
    public let parent: PrimPath?
    public let index: Int
    /// The pivot Xform (with the re-parented part nested inside) to insert.
    public let pivot: Prim
    /// The validated joint being authored.
    public let joint: Joint

    public var label: String { "Add \(joint.kind == .revolute ? "Hinge" : "Slider") to \(original.name)" }

    /// Path of the created pivot Xform (select it / drive it after the edit).
    public var pivotPath: PrimPath { pivot.path }
    /// Path the moving part now lives at (nested under the pivot).
    public var movedPartPath: PrimPath { pivot.path.appending(original.path.name) ?? pivot.path }

    /// Build the command by reading the current stage. Returns `nil` when the
    /// target is missing/root, the joint is invalid, or names can't be resolved.
    public static func make(target: PrimPath,
                            joint proposed: Joint,
                            in stage: any USDStageProtocol) -> CreateJointCommand? {
        guard !target.isRoot, let original = stage.prim(at: target),
              let index = StructureSupport.index(of: target, in: stage) else { return nil }

        // Keep the joint's `target` consistent with the prim it is authored on,
        // then hard-gate on validity — we never author a malformed mechanism.
        var joint = proposed
        joint.target = target.name
        guard JointInvariants.isValid(joint) else { return nil }

        let parent = StructureSupport.parent(of: target)
        let pivotName = StructureSupport.uniqueName(
            base: "\(target.name)_pivot", amongst: StructureSupport.siblingNames(of: parent, in: stage))
        guard let pivotPath = StructureSupport.childPath(parent: parent, name: pivotName),
              let childPath = pivotPath.appending(target.name) else { return nil }

        // The part loads in its default state (closed → rest = T(pivot)); the
        // child's re-parent transform keeps its world placement unchanged there.
        let childLocal = localTransformRowMajor(of: target, in: stage)
        let defaultValue = joint.value(ofState: joint.defaultState) ?? 0
        let pivotTransform = PivotMath.pivotTransformRowMajor(joint, value: defaultValue)
        let childReparent = PivotMath.childReparentRowMajor(joint, childLocalRowMajor: childLocal)

        var movedChild = original
        InMemoryStage.reparentPaths(&movedChild, to: childPath)
        movedChild = StructureSupport.settingTransform(movedChild, to: childReparent)

        let pivot = Prim(
            path: pivotPath,
            typeName: "Xform",
            attributes: [
                Attribute(name: transformAttributeName, value: .matrix4(pivotTransform)),
                Attribute(name: jointAttributeName, value: .string(JointCoding.encode(joint)), isUniform: true),
            ],
            children: [movedChild])

        return CreateJointCommand(original: original, parent: parent, index: index,
                                  pivot: pivot, joint: joint)
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: original.path))
        try stage.apply(.insertPrim(parent: parent, index: index, prim: pivot))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: pivot.path))
        try stage.apply(.insertPrim(parent: parent, index: index, prim: original))
    }
}

/// **Drive a joint** to a named state (e.g. "open"/"closed") or an explicit
/// in-limit value — the "open the door" gesture, and the same seam a variant
/// switcher or timeline scrub uses. Re-authors only the pivot's single
/// `xformOp:transform`, so it is a clean, undoable, round-trip-safe edit.
public struct SetJointStateCommand: EditCommand {
    public let pivotPath: PrimPath
    public let newTransform: [Double]
    public let oldTransform: [Double]
    /// Human-readable target for the label ("open", "35°", …).
    public let stateLabel: String

    public var label: String { "Set \(pivotPath.name) → \(stateLabel)" }

    /// Drive to a named state. Returns `nil` if the pivot carries no joint or the
    /// state is undeclared.
    public static func make(pivotPath: PrimPath, state: String,
                            in stage: any USDStageProtocol) -> SetJointStateCommand? {
        guard let joint = jointOnPivot(pivotPath, in: stage),
              let transform = PivotMath.pivotTransformRowMajor(joint, state: state) else { return nil }
        return build(pivotPath: pivotPath, transform: transform, label: state, in: stage)
    }

    /// Drive to an explicit value (degrees or units). Returns `nil` if the pivot
    /// carries no joint or the value is outside the joint's limits.
    public static func make(pivotPath: PrimPath, value: Double,
                            in stage: any USDStageProtocol) -> SetJointStateCommand? {
        guard let joint = jointOnPivot(pivotPath, in: stage),
              value >= joint.minValue, value <= joint.maxValue else { return nil }
        let transform = PivotMath.pivotTransformRowMajor(joint, value: value)
        let unit = joint.kind == .revolute ? "°" : "u"
        return build(pivotPath: pivotPath, transform: transform,
                     label: "\(formatted(value))\(unit)", in: stage)
    }

    static func build(pivotPath: PrimPath, transform: [Double], label: String,
                      in stage: any USDStageProtocol) -> SetJointStateCommand {
        SetJointStateCommand(pivotPath: pivotPath, newTransform: transform,
                             oldTransform: localTransformRowMajor(of: pivotPath, in: stage),
                             stateLabel: label)
    }

    /// The `Joint` authored on a pivot Xform, if any.
    public static func jointOnPivot(_ pivotPath: PrimPath,
                                    in stage: any USDStageProtocol) -> Joint? {
        guard let attr = stage.prim(at: pivotPath)?.attribute(named: jointAttributeName),
              case let .string(json) = attr.value else { return nil }
        return JointCoding.decode(json)
    }

    static func formatted(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setAttribute(
            path: pivotPath, attribute: Attribute(name: transformAttributeName, value: .matrix4(newTransform))))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.setAttribute(
            path: pivotPath, attribute: Attribute(name: transformAttributeName, value: .matrix4(oldTransform))))
    }
}
