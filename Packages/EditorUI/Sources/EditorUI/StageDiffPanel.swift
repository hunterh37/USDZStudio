import SwiftUI
import USDCore
import DicyaninDesignSystem

/// A flattened, displayable representation of a ``StageDiff`` — the pure model
/// behind the diff panel's list. Keeping the flattening here (rather than inline
/// in the view) makes the "what shows up as a row" logic unit-testable.
enum StageDiffRows {

    enum Kind: Equatable {
        case metadata
        case added
        case removed
        case changed
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let kind: Kind
        /// Primary line — a prim path or a metadata field name.
        let title: String
        /// Secondary line — the before→after summary, or the prim type.
        let detail: String
        /// The prim this row refers to, when clicking it should select something.
        let path: PrimPath?
    }

    /// Flattens a diff into ordered rows: metadata changes, then added, removed,
    /// and per-prim field changes. Deterministic ordering (the engine already
    /// sorts its lists) so snapshots and tests are stable.
    static func rows(for diff: StageDiff) -> [Row] {
        var rows: [Row] = []

        for change in diff.metadata {
            rows.append(Row(id: "meta.\(change.label)", kind: .metadata,
                            title: change.label,
                            detail: summary(change.before, change.after),
                            path: nil))
        }
        for ref in diff.addedPrims {
            rows.append(Row(id: "add.\(ref.path.description)", kind: .added,
                            title: ref.path.description,
                            detail: ref.typeName.isEmpty ? "prim" : ref.typeName,
                            path: ref.path))
        }
        for ref in diff.removedPrims {
            rows.append(Row(id: "rem.\(ref.path.description)", kind: .removed,
                            title: ref.path.description,
                            detail: ref.typeName.isEmpty ? "prim" : ref.typeName,
                            path: ref.path))
        }
        for prim in diff.changedPrims {
            for change in prim.changes {
                rows.append(Row(id: "chg.\(prim.path.description).\(change.label)",
                                kind: .changed,
                                title: "\(prim.path.description) · \(change.label)",
                                detail: summary(change.before, change.after),
                                path: prim.path))
            }
        }
        return rows
    }

    /// A compact "before → after" string, using an em-dash for an absent side
    /// (newly authored, or removed).
    static func summary(_ before: String?, _ after: String?) -> String {
        "\(before ?? "—") → \(after ?? "—")"
    }
}

/// Before/after diff panel (ROADMAP "Continuous · USD stage diff view"). Shows
/// the edits made to the open document since it was opened or last saved,
/// consuming the same pure ``StageDiff`` engine as the CLI `diff` subcommand.
/// Clicking a row selects the affected prim.
struct StageDiffPanel: View {
    let document: EditorDocument?
    let onSelectPrim: (PrimPath) -> Void
    let onClose: () -> Void

    private var diff: StageDiff? { document?.diffFromBaseline }
    private var rows: [StageDiffRows.Row] { diff.map(StageDiffRows.rows) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Palette.panelBackground.color)
    }

    private var header: some View {
        PanelHeader("Changes", systemImage: "plusminus.circle") {
            HStack(spacing: Spacing.xs) {
                StatusPill(text: "\(rows.count) change\(rows.count == 1 ? "" : "s")",
                           tint: rows.isEmpty ? Palette.textSecondary : Palette.accent)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .help("Close diff panel")
                    .accessibilityLabel("Close diff panel")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if document == nil {
            centered("Open a document to see its changes.")
        } else if rows.isEmpty {
            centered("No changes since the file was opened or last saved.")
        } else {
            List(rows) { row in
                diffRow(row)
                    .contentShape(Rectangle())
                    .onTapGesture { if let path = row.path { onSelectPrim(path) } }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func diffRow(_ row: StageDiffRows.Row) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon(row.kind))
                .foregroundStyle(tint(row.kind).color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label(row.kind)): \(row.title). \(row.detail)")
    }

    private func icon(_ kind: StageDiffRows.Kind) -> String {
        switch kind {
        case .metadata: "doc.badge.gearshape"
        case .added: "plus.circle"
        case .removed: "minus.circle"
        case .changed: "pencil.circle"
        }
    }

    private func tint(_ kind: StageDiffRows.Kind) -> ColorToken {
        switch kind {
        case .metadata: Palette.textSecondary
        case .added: Palette.success
        case .removed: Palette.error
        case .changed: Palette.warning
        }
    }

    private func label(_ kind: StageDiffRows.Kind) -> String {
        switch kind {
        case .metadata: "Metadata changed"
        case .added: "Added"
        case .removed: "Removed"
        case .changed: "Changed"
        }
    }

    private func centered(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
