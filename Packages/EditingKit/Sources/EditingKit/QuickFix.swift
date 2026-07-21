import USDCore
import ValidationKit
import MeshKit

/// A one-click remediation for a `Diagnostic`: a human-readable title plus the
/// undoable `EditCommand` that resolves it (specs/validation.md — quick-fixes).
///
/// Quick-fixes are the seam the diagnostics drawer's "Fix" button and a future
/// CLI `validate --fix` both drive. They are *derived*, not authored: the
/// registry inspects the current stage and builds the command on demand, so a
/// fix always reflects live state rather than the stage as it was when the
/// diagnostic was first emitted.
public struct QuickFix: Sendable {
    /// The `ValidationRule.id` this fix remediates.
    public let ruleID: String
    /// Menu/button label, e.g. "Set defaultPrim to 'Car'".
    public let title: String
    /// The undoable command that applies the fix. Runs through the same
    /// `CommandStack` as any manual edit, so it participates in Edit ▸ Undo.
    public let command: any EditCommand

    public init(ruleID: String, title: String, command: any EditCommand) {
        self.ruleID = ruleID
        self.title = title
        self.command = command
    }
}

/// Maps diagnostics from the ARKit validation catalog to undoable fixes.
///
/// Only rules with a *safe, unambiguous, cleanly reversible* remedy get a fix —
/// normalizing scale, picking a `defaultPrim`, dropping a pointless empty mesh,
/// or deriving the normals a renderer would otherwise have to guess at. Rules
/// whose repair needs human judgement (topology corruption, unbound materials)
/// return `nil`, and so do those whose fix cannot round-trip through the
/// mutation layer's uniqueness guard: de-duplicating shadowed sibling names is
/// left to manual rename in the outliner, because undoing it would have to
/// recreate the name collision the stage forbids. The drawer simply shows no Fix
/// button when there is no fix.
///
/// `stage.upAxis` deliberately has no quick-fix. Flipping the metadata token
/// alone silently *reinterprets* the existing geometry rather than re-orienting
/// it, so the "fix" would tip the model on its side while reporting success —
/// a correct remedy has to rotate the scene's roots, which is a modelling
/// decision (which pivot, which prims) the user has to make. Re-orient on
/// export instead.
public enum QuickFixRegistry {

    /// The fix for a single diagnostic, or `nil` when the rule has no automatic
    /// remedy or nothing needs doing against the current stage.
    public static func quickFix(
        for diagnostic: Diagnostic,
        in stage: any USDStageProtocol
    ) -> QuickFix? {
        switch diagnostic.ruleID {
        case MetersPerUnitRule().id:
            return scaleFix(diagnostic, stage)
        case DefaultPrimRule().id:
            return defaultPrimFix(diagnostic, stage)
        case UpAxisRule().id:
            return upAxisFix(diagnostic, stage)
        case EmptyMeshRule().id:
            return emptyMeshFix(diagnostic, stage)
        case MissingNormalsRule().id:
            return normalsFix(diagnostic, stage)
        default:
            return nil
        }
    }

    /// All available fixes for a report, preserving the report's most-severe-first
    /// ordering. Diagnostics without a fix are dropped.
    public static func quickFixes(
        for report: ValidationReport,
        in stage: any USDStageProtocol
    ) -> [(diagnostic: Diagnostic, fix: QuickFix)] {
        report.diagnostics.compactMap { diagnostic in
            quickFix(for: diagnostic, in: stage).map { (diagnostic, $0) }
        }
    }

    // MARK: - Individual fixes

    /// Reuse the scale fixer: normalize `metersPerUnit` to 1.0 while preserving
    /// real-world size.
    private static func scaleFix(_ diagnostic: Diagnostic, _ stage: any USDStageProtocol) -> QuickFix? {
        guard let command = ScaleFixer.command(for: stage) else { return nil }
        return QuickFix(
            ruleID: diagnostic.ruleID,
            title: "Normalize scale to metersPerUnit = 1",
            command: command)
    }

    /// Point `defaultPrim` at the first root prim. Covers both the "none
    /// declared" warning and the "names a missing prim" error.
    private static func defaultPrimFix(_ diagnostic: Diagnostic, _ stage: any USDStageProtocol) -> QuickFix? {
        guard let first = stage.rootPrims.first else { return nil }
        let old = stage.metadata
        guard old.defaultPrim != first.name else { return nil }
        var updated = old
        updated.defaultPrim = first.name
        return QuickFix(
            ruleID: diagnostic.ruleID,
            title: "Set defaultPrim to '\(first.name)'",
            command: SetStageMetadataCommand(newMetadata: updated, oldMetadata: old))
    }

    /// Re-orient a Z-up stage to Y-up, baking a compensating rotation into the
    /// roots so the model keeps its rendered orientation.
    private static func upAxisFix(_ diagnostic: Diagnostic, _ stage: any USDStageProtocol) -> QuickFix? {
        guard let command = UpAxisFixer.command(for: stage) else { return nil }
        return QuickFix(
            ruleID: diagnostic.ruleID,
            title: "Re-orient to Y-up",
            command: command)
    }

    /// Delete a mesh that carries no points. It contributes nothing to the
    /// render, and `RemovePrimCommand` captures the whole prim snapshot plus its
    /// sibling slot, so undo puts it back exactly where it was.
    ///
    /// Anchored to the diagnostic's `primPath` rather than a search, so the fix
    /// targets the prim the row is pointing at even when several meshes are
    /// empty. Returns `nil` if the prim has since gained points or vanished.
    private static func emptyMeshFix(_ diagnostic: Diagnostic, _ stage: any USDStageProtocol) -> QuickFix? {
        guard let path = diagnostic.primPath,
              let prim = stage.prim(at: path),
              prim.typeName == "Mesh",
              MeshNormals.points(of: prim)?.isEmpty ?? true,
              let index = StructureSupport.index(of: path, in: stage) else { return nil }
        return QuickFix(
            ruleID: diagnostic.ruleID,
            title: "Delete empty mesh '\(prim.name)'",
            command: RemovePrimCommand(
                prim: prim, parent: StructureSupport.parent(of: path), index: index))
    }

    /// Author area-weighted smooth vertex normals on a mesh that has none.
    ///
    /// Reversible by construction: the attribute did not exist (that is what the
    /// rule detects), so `SetAttributeCommand`'s `oldAttribute: nil` undo clears
    /// it again and returns the prim to byte-identical state. Returns `nil` when
    /// the topology is degenerate — a mesh whose normals cannot be derived is a
    /// `mesh.topology` problem, not a normals one, and this fix must not paper
    /// over it.
    private static func normalsFix(_ diagnostic: Diagnostic, _ stage: any USDStageProtocol) -> QuickFix? {
        guard let path = diagnostic.primPath,
              let prim = stage.prim(at: path),
              prim.attribute(named: "normals") == nil,
              let normals = MeshNormals.smoothVertexNormals(of: prim) else { return nil }
        return QuickFix(
            ruleID: diagnostic.ruleID,
            title: "Compute smooth normals for '\(prim.name)'",
            command: SetAttributeCommand(
                path: path,
                newAttribute: Attribute(
                    name: "normals",
                    value: .float3Array(normals),
                    metadata: ["interpolation": "\"vertex\""]),
                oldAttribute: nil))
    }
}

/// Derives vertex normals from a mesh prim's authored topology.
///
/// Kept separate from `QuickFixRegistry` so the geometry math is unit-testable
/// on its own, and so a future "recompute normals" menu command can reuse it
/// without going through a diagnostic.
enum MeshNormals {

    /// The prim's `points` as a flat `[x, y, z, …]` array, or `nil` when the
    /// attribute is absent or not a point array. An authored-but-empty array
    /// reads as `[]`, which is what distinguishes "empty mesh" from "not a mesh".
    static func points(of prim: Prim) -> [Double]? {
        switch prim.attribute(named: "points")?.value {
        case .float3Array(let v), .doubleArray(let v): return v
        default: return nil
        }
    }

    /// The prim's named attribute as an integer array, or `nil` when absent or
    /// of another type. (`ValidationKit` has the same accessor, but internally.)
    static func intArray(_ prim: Prim, _ name: String) -> [Int]? {
        if case .intArray(let v)? = prim.attribute(named: name)?.value { return v }
        return nil
    }

    /// Area-weighted smooth vertex normals as a flat `[x, y, z, …]` array
    /// parallel to `points`.
    ///
    /// The geometry math is not duplicated here: this reads the prim's authored
    /// topology into a `MeshKit.FlatMesh` and defers to `VertexNormals`, the
    /// single source of truth for smooth-normal math (issue #95). Returns `nil`
    /// for topology that cannot be honestly interpreted — a non-mesh prim,
    /// missing/mismatched arrays, faces under 3 corners, or out-of-range indices
    /// — so a `mesh.normals` fix is offered only when it can be authored
    /// correctly; a degenerate mesh is a `mesh.topology` problem instead.
    static func smoothVertexNormals(of prim: Prim) -> [Double]? {
        guard prim.typeName == "Mesh",
              let points = points(of: prim), !points.isEmpty, points.count % 3 == 0,
              let counts = intArray(prim, "faceVertexCounts"),
              let indices = intArray(prim, "faceVertexIndices") else { return nil }

        var vertices: [SIMD3<Double>] = []
        vertices.reserveCapacity(points.count / 3)
        for i in stride(from: 0, to: points.count, by: 3) {
            vertices.append(SIMD3(points[i], points[i + 1], points[i + 2]))
        }
        let flat = FlatMesh(points: vertices, faceVertexCounts: counts, faceVertexIndices: indices)
        let normals = VertexNormals.smoothFlat(for: flat)
        // `VertexNormals` returns an empty array for topology it declines; that
        // is precisely the "not a normals fix" case, so map it back to `nil`.
        return normals.isEmpty ? nil : normals
    }
}
