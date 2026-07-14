import SwiftUI
import USDCore
import ViewportKit
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
    /// Source file for the viewport's RealityKit fast path (Phase 1).
    let modelURL: URL?
    @State private var selection = Selection.empty
    @State private var searchText = ""

    public init(stage: (any USDStageProtocol)? = nil, modelURL: URL? = nil) {
        self.stage = stage
        self.modelURL = modelURL
    }

    public var body: some View {
        HSplitView {
            outliner
                .frame(minWidth: 220, idealWidth: 260)
            viewport
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

    @ViewBuilder
    private var viewport: some View {
        if let modelURL {
            ViewportPane(modelURL: modelURL)
        } else {
            ZStack {
                Palette.viewportBackground.color
                Text("Open a USDZ to begin")
                    .font(.system(size: TypeScale.title))
                    .foregroundStyle(Palette.textSecondary.color)
            }
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
