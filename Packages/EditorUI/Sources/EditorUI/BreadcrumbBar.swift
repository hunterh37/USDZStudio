import SwiftUI
import USDCore
import DicyaninDesignSystem

/// The drill-down breadcrumb shown along the top of the viewport (ROADMAP
/// Milestone 3). It renders the selection's ancestor trail — click any crumb to
/// jump to that depth, the ⌄ button walks up one level — and surfaces the
/// isolate-mode state with a one-tap exit.
///
/// All navigation logic lives in `PartSelection` / `EditorDocument` and is
/// unit-tested there; this view is a thin projection of `document.breadcrumb`.
struct BreadcrumbBar: View {
    @Bindable var document: EditorDocument

    var body: some View {
        let crumbs = document.breadcrumb
        if !crumbs.isEmpty || document.isolation.isActive {
            HStack(spacing: 6) {
                if document.selection.primary.map({ PartSelection.walkUp(from: $0) != nil }) == true {
                    Button {
                        document.walkUpSelection()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .help("Select parent (⌘↑)")
                }

                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                    Button {
                        document.selection = Selection([crumb.path])
                    } label: {
                        Text(crumb.name)
                            .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                            .foregroundStyle(index == crumbs.count - 1
                                             ? Palette.textPrimary.color
                                             : Palette.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                }

                if document.isolation.isActive {
                    Divider().frame(height: 12)
                    Button {
                        document.exitIsolation()
                    } label: {
                        Label("Isolated", systemImage: "square.dashed.inset.filled")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent.color)
                    .help("Exit isolate mode")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }
}
