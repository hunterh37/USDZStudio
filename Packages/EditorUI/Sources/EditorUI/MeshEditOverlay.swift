import SwiftUI
import USDCore
import MeshKit
import DicyaninDesignSystem

/// Viewport overlay for mesh edit mode (specs/mesh-editing.md §Component mode).
///
/// Always answers "what mode am I in, and what tool is active?" at a glance:
/// - top-left: EDIT MODE badge + vertex/edge/face sub-mode (1/2/3)
/// - top-center: large active-tool indicator (name + icon), amber while armed
/// - bottom-center: tool strip (E/I/X/M/F) with the active tool highlighted,
///   plus the parameter HUD and Apply/Done controls
/// - refusals/diagnostics surface inline, never silently
public struct MeshEditOverlay: View {
    @Bindable var document: EditorDocument

    public init(document: EditorDocument) { self.document = document }

    public var body: some View {
        if document.meshEdit != nil {
            ZStack {
                VStack {
                    header
                    Spacer()
                    bottomStack
                }
                .padding(Spacing.md)
            }
            .background(hotkeyHandler)
        }
    }

    private var state: MeshEditState? { document.meshEdit }

    // MARK: Header — mode badge + active tool indicator

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Circle().fill(Palette.warning.color).frame(width: 7, height: 7)
                    Text("EDIT MODE")
                        .font(.system(size: TypeScale.label, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.warning.color)
                    Text("— \(document.meshEdit?.session.path.name ?? "")")
                        .font(.system(size: TypeScale.label))
                        .foregroundStyle(Palette.textSecondary.color)
                }
                componentModePicker
            }
            .padding(Spacing.sm)
            .background(hudBackground)

            Spacer()

            activeToolIndicator

            Spacer()

            Button {
                document.exitMeshEditMode()
            } label: {
                Label("Done (⇥)", systemImage: "checkmark")
                    .font(.system(size: TypeScale.label, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(Spacing.sm)
            .background(hudBackground)
            .help("Commit mesh edits and return to object mode (Tab)")
            .accessibilityIdentifier("meshEdit.done")
        }
    }

    /// The unmissable "what tool is live" readout.
    private var activeToolIndicator: some View {
        HStack(spacing: Spacing.sm) {
            if let tool = state?.tool {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.warning.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.label.uppercased())
                        .font(.system(size: TypeScale.heading, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Palette.textPrimary.color)
                    if let hovered = state?.hoveredFaceIndex, state?.hoverPreviewEnabled == true {
                        Text("will \(tool.label.lowercased()) Face \(hovered + 1) — click to select, ⇧click to add")
                            .font(.system(size: TypeScale.caption, weight: .semibold))
                            .foregroundStyle(Palette.accent.color)
                    } else {
                        Text("press ⏎ to apply · esc to disarm")
                            .font(.system(size: TypeScale.caption))
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                }
            } else {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary.color)
                // Built from MeshTool so new tools (e.g. Bevel/B) show up
                // without touching this string again.
                Text("No tool — press " + MeshTool.allCases
                    .map { String($0.hotkey).uppercased() }
                    .joined(separator: " · "))
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Palette.surfaceElevated.color.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .strokeBorder(state?.tool != nil
                                      ? Palette.warning.color.opacity(0.7)
                                      : Palette.panelBorder.color, lineWidth: 1.5))
        )
        .accessibilityIdentifier("meshEdit.activeTool")
    }

    private var componentModePicker: some View {
        HStack(spacing: 2) {
            ForEach(MeshComponentMode.allCases) { mode in
                let active = state?.mode == mode
                Button {
                    document.meshEdit?.mode = mode
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                        .labelStyle(.iconOnly)
                        .font(.system(size: TypeScale.label))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(active ? Palette.accent.color.opacity(0.3) : .clear))
                        .foregroundStyle(active ? Palette.accent.color : Palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .help("\(mode.label) select (\(MeshComponentMode.allCases.firstIndex(of: mode)! + 1))")
            }
        }
    }

    // MARK: Bottom — tool strip + param HUD

    private var bottomStack: some View {
        VStack(spacing: Spacing.sm) {
            if let drag = state?.gizmoDrag {
                // Live drag-extrude readout (the gizmo is the input; this is
                // the number, matching Blender's header readout during E-drag).
                Label(String(format: "Extrude %+.3f", drag.distance),
                      systemImage: "arrow.up.and.down")
                    .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.warning.color)
                    .padding(Spacing.sm)
                    .background(hudBackground)
                    .accessibilityIdentifier("meshEdit.gizmoReadout")
            }
            if let diagnostic = state?.lastDiagnostic {
                Label(diagnostic, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Palette.warning.color)
                    .padding(Spacing.sm)
                    .background(hudBackground)
                    .accessibilityIdentifier("meshEdit.diagnostic")
            }
            facePicker
            paramHUD
            toolStrip
        }
    }

    private var toolStrip: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(MeshTool.allCases) { tool in
                let active = state?.tool == tool
                Button {
                    document.meshEdit?.tool = active ? nil : tool
                    document.meshEdit?.lastDiagnostic = nil
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 14, weight: .medium))
                        Text(tool.label)
                            .font(.system(size: TypeScale.caption, weight: active ? .bold : .regular))
                        Text(String(tool.hotkey).uppercased())
                            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
                            .foregroundStyle(active ? Palette.warning.color : Palette.textTertiary.color)
                    }
                    .frame(width: 64, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(active ? Palette.warning.color.opacity(0.18) : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .strokeBorder(active ? Palette.warning.color : .clear, lineWidth: 1.5)))
                    .foregroundStyle(active ? Palette.textPrimary.color : Palette.textSecondary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.label) (\(String(tool.hotkey).uppercased()))")
                .accessibilityIdentifier("meshEdit.tool.\(tool.rawValue)")
            }

            Divider().frame(height: 36)

            hoverToggle

            Button {
                document.undoMeshEdit()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14))
                    Text("Undo Op")
                        .font(.system(size: TypeScale.caption))
                }
                .frame(width: 58, height: 52)
                .foregroundStyle(Palette.textSecondary.color)
            }
            .buttonStyle(.plain)
            .disabled(!(state?.session.canUndo ?? false))
        }
        .padding(Spacing.sm)
        .background(hudBackground)
    }

    /// Toggle the live hover preview (blue highlight on the face under the
    /// cursor — what the armed tool would act on).
    private var hoverToggle: some View {
        let enabled = state?.hoverPreviewEnabled == true
        return Button {
            document.meshEdit?.hoverPreviewEnabled.toggle()
            if document.meshEdit?.hoverPreviewEnabled == false {
                document.meshEdit?.hoveredFaceIndex = nil
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: enabled ? "cursorarrow.rays" : "cursorarrow.slash")
                    .font(.system(size: 14, weight: .medium))
                Text("Hover")
                    .font(.system(size: TypeScale.caption, weight: enabled ? .bold : .regular))
            }
            .frame(width: 58, height: 52)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(enabled ? Palette.accent.color.opacity(0.18) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(enabled ? Palette.accent.color : .clear, lineWidth: 1.5)))
            .foregroundStyle(enabled ? Palette.accent.color : Palette.textSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Live hover preview: highlight the face under the cursor")
        .accessibilityIdentifier("meshEdit.hoverToggle")
    }

    /// Interim component selection until viewport picking lands: step through
    /// faces in authored order, or grab them all.
    @ViewBuilder
    private var facePicker: some View {
        if let state {
            let count = state.session.mesh.faceOrder.count
            HStack(spacing: Spacing.xs) {
                Text("Selection")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(Palette.textSecondary.color)
                Button {
                    document.selectMeshFace(index: (state.selectedFaceIndex ?? 0) - 1)
                } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("meshEdit.face.prev")
                Text(facePickerLabel(state: state, count: count))
                    .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.accent.color)
                    .frame(minWidth: 110)
                Button {
                    document.selectMeshFace(index: (state.selectedFaceIndex ?? -1) + 1)
                } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("meshEdit.face.next")
                Divider().frame(height: 14)
                Button("All") { document.selectMeshFace(index: nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: TypeScale.label, weight: .medium))
                    .foregroundStyle(state.selectedFaceIndex == nil
                                     && document.meshEditSelectedFaceCount == count
                                     ? Palette.accent.color : Palette.textSecondary.color)
                    .accessibilityIdentifier("meshEdit.face.all")
            }
            .padding(Spacing.sm)
            .background(hudBackground)
        }
    }

    /// Face-picker readout: single face → position; ⇧-click multi-select →
    /// selection count; everything → "All"; none → prompt.
    private func facePickerLabel(state: MeshEditState, count: Int) -> String {
        if let index = state.selectedFaceIndex { return "Face \(index + 1) of \(count)" }
        let selected = document.meshEditSelectedFaceCount
        if selected == 0 { return "No faces — click one" }
        if selected == count { return "All \(count) faces" }
        return "\(selected) of \(count) faces"
    }

    @ViewBuilder
    private var paramHUD: some View {
        if let tool = state?.tool {
            HStack(spacing: Spacing.sm) {
                switch tool {
                case .extrude:
                    paramField("Distance", value: Binding(
                        get: { document.meshEdit?.extrudeDistance ?? 0.1 },
                        set: { document.meshEdit?.extrudeDistance = $0 }))
                case .inset:
                    paramField("Fraction", value: Binding(
                        get: { document.meshEdit?.insetFraction ?? 0.2 },
                        set: { document.meshEdit?.insetFraction = $0 }))
                    paramField("Depth", value: Binding(
                        get: { document.meshEdit?.insetDepth ?? -0.1 },
                        set: { document.meshEdit?.insetDepth = $0 }))
                case .merge:
                    paramField("Distance", value: Binding(
                        get: { document.meshEdit?.mergeDistance ?? 0.001 },
                        set: { document.meshEdit?.mergeDistance = $0 }))
                case .bevel:
                    paramField("Width", value: Binding(
                        get: { document.meshEdit?.bevelWidth ?? 0.05 },
                        set: { document.meshEdit?.bevelWidth = $0 }))
                    let edgeCount = document.meshEditEdges.count
                    let idx = document.meshEdit?.selectedEdgeIndex ?? 0
                    Text("Edge \(min(idx, max(edgeCount - 1, 0)) + 1)/\(edgeCount)")
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary.color)
                    Button { document.selectMeshEdge(index: idx - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("meshEdit.edge.prev")
                    Button { document.selectMeshEdge(index: idx + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityIdentifier("meshEdit.edge.next")
                case .mirror:
                    Picker("Axis", selection: Binding(
                        get: { document.meshEdit?.mirrorAxis ?? .x },
                        set: { document.meshEdit?.mirrorAxis = $0 })) {
                        Text("X").tag(MeshKit.Mirror.Axis.x)
                        Text("Y").tag(MeshKit.Mirror.Axis.y)
                        Text("Z").tag(MeshKit.Mirror.Axis.z)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .accessibilityIdentifier("meshEdit.mirror.axis")
                    paramField("Plane", value: Binding(
                        get: { document.meshEdit?.mirrorCoordinate ?? 0 },
                        set: { document.meshEdit?.mirrorCoordinate = $0 }))
                case .solidify:
                    paramField("Thickness", value: Binding(
                        get: { document.meshEdit?.solidifyThickness ?? 0.05 },
                        set: { document.meshEdit?.solidifyThickness = $0 }))
                case .delete, .fill:
                    Text("No parameters")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textTertiary.color)
                }
                Button("Apply") { document.applyActiveMeshTool() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("meshEdit.apply")
            }
            .padding(Spacing.sm)
            .background(hudBackground)
        }
    }

    private func paramField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(label)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(Palette.textSecondary.color)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                .frame(width: 72)
        }
    }

    private var hudBackground: some View {
        RoundedRectangle(cornerRadius: Radius.lg)
            .fill(Palette.surfaceElevated.color.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
    }

    // MARK: Hotkeys (E/I/X/M/F arm a tool, ⏎ applies, esc disarms, 1/2/3 sub-modes)

    private var hotkeyHandler: some View {
        Group {
            ForEach(MeshTool.allCases) { tool in
                Button("") {
                    document.meshEdit?.tool = tool
                    document.meshEdit?.lastDiagnostic = nil
                }
                .keyboardShortcut(KeyEquivalent(tool.hotkey), modifiers: [])
            }
            ForEach(Array(MeshComponentMode.allCases.enumerated()), id: \.element) { i, mode in
                Button("") { document.meshEdit?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
            }
            Button("") { document.applyActiveMeshTool() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { document.meshEdit?.tool = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}
