import USDCore
import ValidationKit

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
/// normalizing scale or picking a `defaultPrim`. Rules whose repair needs human
/// judgement (topology corruption, missing normals, unbound materials) return
/// `nil`, and so do those whose fix cannot round-trip through the mutation
/// layer's uniqueness guard: de-duplicating shadowed sibling names is left to
/// manual rename in the outliner, because undoing it would have to recreate the
/// name collision the stage forbids. The drawer simply shows no Fix button when
/// there is no fix.
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
}
