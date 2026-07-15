import SwiftUI
import USDCore
import ValidationKit
import EditingKit
import DicyaninDesignSystem

/// Live diagnostics drawer (Phase 4). Runs the ARKit-profile `ValidationEngine`
/// over the open stage and lists results; clicking a diagnostic selects the
/// offending prim in the outliner/inspector (specs/validation.md).
struct ValidationDrawer: View {
    let stage: (any USDStageProtocol)?
    /// Selecting a diagnostic's prim drives the shared selection.
    let onSelectPrim: (PrimPath) -> Void
    /// A quick-fix for the diagnostic, or `nil` when none is available (read-only
    /// preview, or a rule with no automatic remedy).
    let quickFix: (Diagnostic) -> QuickFix?
    /// Applies a diagnostic's quick-fix (one undoable command), then re-runs
    /// validation so the list reflects the repaired stage.
    let onApplyFix: (Diagnostic) -> Void
    let onClose: () -> Void

    @State private var report: ValidationReport?

    private var engine: ValidationEngine { .arkitProfile }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.panelBorder.color)
            content
        }
        .background(Palette.panelBackground.color)
        .onAppear(perform: revalidate)
        .onChange(of: stageIdentity) { _, _ in revalidate() }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("Validation")
                .font(.system(size: TypeScale.heading, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            if let report {
                summaryChip(count: report.errorCount, label: "errors", color: Palette.error)
                summaryChip(count: report.warningCount, label: "warnings", color: Palette.warning)
                summaryChip(count: report.infoCount, label: "info", color: Palette.textSecondary)
                if report.isCompliant {
                    Label("AR-ready", systemImage: "checkmark.seal.fill")
                        .font(.system(size: TypeScale.body, weight: .medium))
                        .foregroundStyle(Palette.accent.color)
                }
            }
            Spacer()
            Button(action: revalidate) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary.color)
                .help("Re-run validation")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary.color)
                .help("Close drawer")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        if stage == nil {
            centered("Open a stage to validate it.")
        } else if let report {
            if report.diagnostics.isEmpty {
                centered("No issues found against the ARKit profile.")
            } else {
                List(Array(report.diagnostics.enumerated()), id: \.offset) { _, diag in
                    diagnosticRow(diag)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { if let p = diag.primPath { onSelectPrim(p) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else {
            centered("Validating…")
        }
    }

    private func diagnosticRow(_ diag: Diagnostic) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: icon(for: diag.severity))
                .foregroundStyle(color(for: diag.severity).color)
                .font(.system(size: TypeScale.body))
            VStack(alignment: .leading, spacing: 1) {
                Text(diag.message)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                HStack(spacing: Spacing.xs) {
                    Text(diag.ruleID)
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                    if let path = diag.primPath {
                        Text(path.description)
                            .font(.system(size: TypeScale.caption, design: .monospaced))
                    }
                }
                .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer(minLength: 0)
            if let fix = quickFix(diag) {
                Button(fix.title) { onApplyFix(diag); revalidate() }
                    .buttonStyle(.borderless)
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent.color)
                    .help(fix.title)
            }
        }
        .padding(.vertical, 2)
    }

    private func summaryChip(count: Int, label: String, color: ColorToken) -> some View {
        Text("\(count) \(label)")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.color.opacity(count > 0 ? 0.22 : 0.08)))
            .foregroundStyle(count > 0 ? color.color : Palette.textSecondary.color)
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Palette.textSecondary.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(for s: DiagnosticSeverity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for s: DiagnosticSeverity) -> ColorToken {
        switch s {
        case .error: return Palette.error
        case .warning: return Palette.warning
        case .info: return Palette.textSecondary
        }
    }

    /// A cheap identity so validation re-runs when the open stage changes.
    private var stageIdentity: String {
        guard let stage else { return "none" }
        return (stage.sourceURL?.path ?? "mem") + "#\(stage.primCount)"
    }

    private func revalidate() {
        guard let stage else { report = nil; return }
        report = engine.validate(stage)
    }
}
