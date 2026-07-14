import SwiftUI
import USDCore
import DicyaninDesignSystem

extension ColorToken {
    /// Maps a design-system token to SwiftUI.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Phase 0 chrome: left outliner / center viewport placeholder / right
/// inspector placeholder (specs/editor-ui.md). Panels become real in Phase 1.
public struct EditorShellView: View {

    let stage: (any USDStageProtocol)?
    @State private var selection = Selection.empty
    @State private var searchText = ""

    public init(stage: (any USDStageProtocol)? = nil) {
        self.stage = stage
    }

    public var body: some View {
        HSplitView {
            outliner
                .frame(minWidth: 220, idealWidth: 260)
            viewportPlaceholder
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            inspectorPlaceholder
                .frame(minWidth: 240, idealWidth: 280)
        }
        .background(Palette.windowBackground.color)
    }

    private var outliner: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(Spacing.xs)
            List(filteredRows) { row in
                HStack(spacing: Spacing.xxs) {
                    Text(row.path.name)
                        .font(.system(size: TypeScale.body))
                        .foregroundStyle(row.isActive
                            ? Palette.textPrimary.color
                            : Palette.textSecondary.color)
                    Spacer()
                    if row.visibility == .invisible {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
                .padding(.leading, Double(row.depth) * Spacing.sm)
                .contentShape(Rectangle())
                .onTapGesture { selection = selection.selecting(row.path) }
            }
            .listStyle(.sidebar)
        }
        .background(Palette.panelBackground.color)
    }

    private var filteredRows: [OutlinerModel.Row] {
        guard let stage else { return [] }
        return OutlinerModel.filtered(OutlinerModel.rows(for: stage), searchText: searchText)
    }

    private var viewportPlaceholder: some View {
        ZStack {
            Palette.viewportBackground.color
            Text(stage == nil ? "Open a USDZ to begin" : "Viewport — Phase 1")
                .font(.system(size: TypeScale.title))
                .foregroundStyle(Palette.textSecondary.color)
        }
    }

    private var inspectorPlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Inspector")
                .font(.system(size: TypeScale.heading, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            if let path = selection.primary {
                Text(path.description)
                    .font(.system(size: TypeScale.body, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary.color)
            } else {
                Text("No selection")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panelBackground.color)
    }
}
