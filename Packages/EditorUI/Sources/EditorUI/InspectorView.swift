import SwiftUI
import USDCore
import EditingKit
import DicyaninDesignSystem

/// The inspector, in the Blender-4.x Properties-editor idiom: a vertical icon
/// tab rail down the left edge, flat collapsible sections, and scrub-draggable
/// value fields (`ScrubField`). Every edit still routes through the document's
/// `CommandStack` so it stays undoable.
///
/// Public so the offscreen harness (`Tools/EditorHarness`) can render a single
/// panel state without standing up the whole shell — the panel-snapshot layer in
/// specs/testing.md.
public struct InspectorView: View {
    /// nil when no file is open — the tabs then render empty states.
    let document: EditorDocument?

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case prim = "Prim"
        case transform = "Transform"
        case states = "States"
        case material = "Material"
        case stage = "Stage"
        public var id: String { rawValue }

        var icon: String {
            switch self {
            case .prim: return "cube"
            case .transform: return "move.3d"
            case .states: return "switch.2"
            case .material: return "paintpalette"
            case .stage: return "square.stack.3d.up"
            }
        }
    }

    @State private var tab: Tab

    /// - Parameter initialTab: the tab shown on first render. The user's clicks
    ///   take over from there; this only seeds it.
    public init(document: EditorDocument?, initialTab: Tab = .prim) {
        self.document = document
        _tab = State(initialValue: initialTab)
    }

    private var stage: (any USDStageProtocol)? { document?.snapshot }
    private var selection: Selection { document?.selection ?? .empty }

    private var prim: Prim? {
        guard let stage, let path = selection.primary else { return nil }
        return stage.prim(at: path)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Inspector", systemImage: "slider.horizontal.3") {
                if let prim {
                    StatusPill(text: prim.name)
                }
            }
            HStack(spacing: 0) {
                tabRail
                Rectangle().fill(Palette.panelBorder.color).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .prim: primTab
                        case .transform: transformTab
                        case .states: statesTab
                        case .material: materialTab
                        case .stage: stageTab
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Palette.panelBackground.color)
    }

    // MARK: Tab rail

    /// Blender's vertical properties-tab strip: icon buttons on a sunken rail,
    /// the active tab filled with the accent wash.
    private var tabRail: some View {
        VStack(spacing: Spacing.xxs) {
            ForEach(Tab.allCases) { t in
                TabRailButton(tab: t, isActive: t == tab) { tab = t }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.xxs)
        .frame(width: 36)
        .background(Palette.surfaceSunken.color)
    }

    private struct TabRailButton: View {
        let tab: Tab
        let isActive: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive
                        ? Palette.accent.color
                        : (hovering ? Palette.textPrimary : Palette.textSecondary).color)
                    .frame(width: 28, height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.md)
                        .fill(isActive
                            ? Palette.accent.color.opacity(0.18)
                            : (hovering ? Palette.surfaceHover.color : .clear)))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tab.rawValue)
            .accessibilityIdentifier("inspector.tab.\(tab.rawValue)")
        }
    }

    // MARK: Prim

    @ViewBuilder
    private var primTab: some View {
        if let document, let prim {
            InspectorSection(title: "Prim",
                             subtitle: prim.typeName.isEmpty ? "(typeless)" : prim.typeName) {
                LabeledField(label: "Name") {
                    NameField(name: prim.name) { document.rename(prim.path, to: $0) }
                }
                FieldRow(label: "Path", value: prim.path.description)
                LabeledField(label: "Active") {
                    Toggle("", isOn: Binding(
                        get: { prim.isActive },
                        set: { document.setActive(prim.path, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                LabeledField(label: "Visibility") {
                    Picker("", selection: Binding(
                        get: { prim.visibility },
                        set: { document.setVisibility(prim.path, $0) })) {
                        ForEach([Visibility.inherited, .invisible], id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
                FieldRow(label: "Children", value: String(prim.children.count))
            }
            if !prim.metadata.isEmpty {
                InspectorSection(title: "Metadata") {
                    ForEach(prim.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        FieldRow(label: k, value: v)
                    }
                }
            }
            attributesSection(prim.attributes)
            if !prim.relationships.isEmpty {
                InspectorSection(title: "Relationships") {
                    ForEach(prim.relationships, id: \.name) { rel in
                        FieldRow(label: rel.name,
                                 value: rel.targets.map(\.description).joined(separator: ", "))
                    }
                }
            }
            if !prim.variantSets.isEmpty {
                InspectorSection(title: "Variant Sets") {
                    ForEach(prim.variantSets, id: \.name) { vs in
                        LabeledField(label: vs.name) {
                            VariantPicker(variantSet: vs) { newSelection in
                                document.setVariantSelection(
                                    prim.path, set: vs.name, to: newSelection)
                            }
                        }
                    }
                }
            }
        } else {
            emptyState("No selection")
        }
    }

    @ViewBuilder
    private func attributesSection(_ attributes: [Attribute]) -> some View {
        if !attributes.isEmpty {
            InspectorSection(title: "Attributes", subtitle: String(attributes.count)) {
                ForEach(attributes.sorted(by: { $0.name < $1.name }), id: \.name) { attr in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Spacing.xs) {
                            Text(attr.name)
                                .font(.system(size: TypeScale.body, weight: .medium))
                                .foregroundStyle(Palette.textPrimary.color)
                            Text(attr.value.typeLabel)
                                .font(.system(size: TypeScale.caption, design: .monospaced))
                                .foregroundStyle(Palette.textSecondary.color)
                            if attr.isUniform { badge("uniform") }
                            if attr.isAnimated { badge("anim") }
                        }
                        Text(ValueFormatter.string(attr.value))
                            .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary.color)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: Transform

    @ViewBuilder
    private var transformTab: some View {
        if let document, let prim {
            TransformEditor(document: document, path: prim.path)
                .id(prim.path)
        } else {
            emptyState("No selection")
        }
    }

    // MARK: States (rigid articulations + discrete variant sets)

    @ViewBuilder
    private var statesTab: some View {
        if let document {
            StatesEditor(document: document)
        } else {
            emptyState("No stage open")
        }
    }

    // MARK: Material

    @ViewBuilder
    private var materialTab: some View {
        if let document, let prim {
            if let material = document.boundMaterial(for: prim.path) {
                MaterialEditor(document: document, material: material, selected: prim.path)
                    .id(material.surfacePath)
            } else if let subtreeMaterial = document.materials(under: selection.paths).first {
                // No material bound to the selected prim itself (e.g. a model root
                // Xform), but parts under it carry materials — surface the
                // model-wide recolor rather than dead-ending.
                MaterialEditor(document: document, material: subtreeMaterial, selected: prim.path)
                    .id(prim.path)
            } else {
                noMaterialState(document: document, prim: prim)
            }
        } else {
            emptyState("No selection")
        }
    }

    /// Shown when the selection has no material anywhere: offers to create and
    /// bind one so the model becomes recolourable. Binding on the selected prim
    /// inherits down, so a model root gets its whole subtree covered.
    private func noMaterialState(document: EditorDocument, prim: Prim) -> some View {
        InspectorSection(title: "Material") {
            Text("No material is bound to \(prim.name).")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
            Button("Create & assign material") {
                document.createAndBindMaterial(to: prim.path)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("material.create")
            Text("Adds a new UsdPreviewSurface material and binds it here. "
                 + "Parts under this prim inherit it, so the whole model becomes "
                 + "recolourable.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textSecondary.color)
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stageTab: some View {
        if let document, let stage {
            let m = stage.metadata
            InspectorSection(title: "Stage") {
                FieldRow(label: "Source", value: stage.sourceURL?.lastPathComponent ?? "—")
                LabeledField(label: "Up axis") {
                    Picker("", selection: Binding(
                        get: { m.upAxis },
                        set: { new in
                            var copy = m; copy.upAxis = new
                            document.setStageMetadata(copy)
                        })) {
                        ForEach([UpAxis.y, UpAxis.z], id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 100)
                }
                LabeledField(label: "Meters/unit") {
                    ScrubField(value: m.metersPerUnit, step: 0.01) { new in
                        var copy = m; copy.metersPerUnit = new
                        document.setStageMetadata(copy)
                    }
                    .frame(maxWidth: 120)
                }
                if m.metersPerUnit != 1.0 {
                    LabeledField(label: "") {
                        Button("Normalize to meters") { document.fixScale() }
                            .buttonStyle(.link)
                            .font(.system(size: TypeScale.body))
                            .help("Set meters/unit to 1 and bake a compensating "
                                  + "scale into each root prim, preserving real-world size.")
                    }
                }
                LabeledField(label: "Default prim") {
                    NameField(name: m.defaultPrim ?? "", allowEmpty: true) { new in
                        var copy = m
                        copy.defaultPrim = new.isEmpty ? nil : new
                        document.setStageMetadata(copy)
                    }
                }
                FieldRow(label: "Prims", value: String(stage.primCount))
            }
            if m.isAnimated {
                InspectorSection(title: "Animation") {
                    FieldRow(label: "Start", value: m.startTimeCode.map { String(format: "%g", $0) } ?? "—")
                    FieldRow(label: "End", value: m.endTimeCode.map { String(format: "%g", $0) } ?? "—")
                    FieldRow(label: "FPS", value: m.timeCodesPerSecond.map { String(format: "%g", $0) } ?? "—")
                }
            }
            if !m.customLayerData.isEmpty {
                InspectorSection(title: "Custom Layer Data") {
                    ForEach(m.customLayerData.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        FieldRow(label: k, value: v)
                    }
                }
            }
        } else {
            emptyState("No stage open")
        }
    }

    // MARK: Helpers

    private func badge(_ text: String) -> some View { Badge(text) }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Palette.textSecondary.color)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editable field building blocks

/// A label + trailing editor laid out like `FieldRow`, for interactive controls.
// (internal: shared with MaterialEditor.swift)
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 96, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// A text field that commits a (validated) name on submit or focus loss, and
/// reverts to the source value if left blank (unless `allowEmpty`).
private struct NameField: View {
    let name: String
    var allowEmpty: Bool = false
    let commit: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(name: String, allowEmpty: Bool = false, commit: @escaping (String) -> Void) {
        self.name = name
        self.allowEmpty = allowEmpty
        self.commit = commit
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("", text: $text)
            .sunkenField()
            .frame(maxWidth: 160)
            .focused($focused)
            .onSubmit(commitIfChanged)
            .onChange(of: focused) { _, isFocused in if !isFocused { commitIfChanged() } }
            .onChange(of: name) { _, new in text = new }   // external rename/undo
    }

    private func commitIfChanged() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && !allowEmpty { text = name; return }
        if trimmed != name { commit(trimmed) }
    }
}

/// A picker over a variant set's authored variants, committing the active
/// selection through the document as one undoable `SetVariantSelectionCommand`.
/// An explicit "None" tag surfaces (and lets the user clear) an unset selection.
private struct VariantPicker: View {
    let variantSet: VariantSet
    let commit: (String?) -> Void

    private let noneTag = "\u{0}none"   // sentinel distinct from any variant name

    var body: some View {
        Picker("", selection: Binding(
            get: { variantSet.selection ?? noneTag },
            set: { commit($0 == noneTag ? nil : $0) })) {
            Text("None").tag(noneTag)
            ForEach(variantSet.variants, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 160)
    }
}

/// Editable T/R/S for a prim in the Blender N-panel idiom — Location / Rotation /
/// Scale sections, each a vertical stack of axis-tinted scrub fields. Every edit
/// commits as one undoable `SetTransformCommand`. Seeded from the prim's current
/// transform; `.id(path)` in the parent re-seeds it when the selection changes.
private struct TransformEditor: View {
    let document: EditorDocument
    let path: PrimPath

    var body: some View {
        let trs = document.transform(at: path)
        VStack(alignment: .leading, spacing: 0) {
            vectorSection("Location", values: trs.translation, step: 0.01) { axis, v in
                var next = trs; next.translation[axis] = v
                document.setTransform(path, to: next, verb: "Move")
            }
            vectorSection("Rotation", values: trs.rotationEulerDegrees,
                          step: 1, suffix: "°") { axis, v in
                var next = trs; next.rotationEulerDegrees[axis] = v
                document.setTransform(path, to: next, verb: "Rotate")
            }
            vectorSection("Scale", values: trs.scale, step: 0.01) { axis, v in
                var next = trs; next.scale[axis] = v
                document.setTransform(path, to: next, verb: "Scale")
            }
            Button("Reset to identity") {
                document.setTransform(path, to: .identity, verb: "Reset Transform")
            }
            .buttonStyle(.link)
            .font(.system(size: TypeScale.body))
            .padding(Spacing.sm)
        }
    }

    private func vectorSection(_ title: String, values: [Double], step: Double,
                               suffix: String = "",
                               set: @escaping (Int, Double) -> Void) -> some View {
        InspectorSection(title: title) {
            ForEach(0..<3, id: \.self) { axis in
                ScrubField(value: values[axis],
                           label: axisLabels[axis],
                           labelTint: axisTint(axis),
                           step: step,
                           suffix: suffix) { set(axis, $0) }
            }
        }
    }
}

// MARK: - States editor (rigid articulations + discrete variant sets)

/// The stage-wide "States" panel: every openable mechanism (hinge/slider) the
/// asset carries, each with a state switcher and a scrub control, plus the
/// stage's discrete variant sets. Unlike the other inspector tabs this is *not*
/// selection-scoped — a loaded USDZ's articulations are a property of the whole
/// asset, and the point of the panel is to discover and drive them without first
/// hunting for the pivot prim in the outliner.
///
/// Declarative only: discovery and driving live in `EditorDocument` +
/// `EditingKit.JointDiscovery`; every toggle/scrub is one undoable command.
struct StatesEditor: View {
    let document: EditorDocument

    var body: some View {
        let joints = document.articulations
        let variantSets = document.stageVariantSets

        if joints.isEmpty && variantSets.isEmpty {
            emptyState
        } else {
            if !joints.isEmpty {
                InspectorSection(title: "Mechanisms", subtitle: String(joints.count)) {
                    ForEach(joints) { joint in
                        JointStateRow(document: document, joint: joint)
                    }
                }
            }
            if !variantSets.isEmpty {
                InspectorSection(title: "Variant Sets", subtitle: String(variantSets.count)) {
                    // A stage may repeat a set name across prims, so key on the
                    // owning path too rather than the set name alone.
                    ForEach(variantSets, id: \.path) { entry in
                        LabeledField(label: entry.set.name) {
                            VariantPicker(variantSet: entry.set) { newSelection in
                                document.setVariantSelection(
                                    entry.path, set: entry.set.name, to: newSelection)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Shown when the asset has no articulations or variants: explains what the
    /// panel is for and how to add a mechanism, rather than dead-ending blank.
    private var emptyState: some View {
        InspectorSection(title: "States") {
            Text("This asset has no openable parts or variant sets.")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
            Text("Give a part a hinge or slider — a lid, door, cap, or drawer — "
                 + "and it appears here as an open/close switch. Add one with the "
                 + "articulation tools (create a joint on the moving part).")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textTertiary.color)
        }
    }
}

/// One mechanism: a state switcher (closed/open/…) over the joint's named states
/// plus a scrub-slider for arbitrary in-limit poses. The active state is
/// highlighted; an in-between (hand-scrubbed) pose highlights nothing.
struct JointStateRow: View {
    let document: EditorDocument
    let joint: DiscoveredJoint

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(joint.name)
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                Badge(joint.kindLabel)
                Spacer(minLength: 0)
                Text(joint.activeState ?? "custom")
                    .font(.system(size: TypeScale.caption, design: .monospaced))
                    .foregroundStyle(Palette.textTertiary.color)
            }

            // State switcher — a segmented row of the joint's named states.
            HStack(spacing: Spacing.xxs) {
                ForEach(joint.stateNames, id: \.self) { state in
                    StateChip(title: state, isActive: state == joint.activeState) {
                        document.setJointState(joint.pivotPath, state: state)
                    }
                }
            }

            // Fine control: scrub anywhere within the joint's limits. Committed on
            // release, so a drag is a single undo entry (ScrubField's contract).
            LabeledField(label: "Value") {
                ScrubField(value: joint.currentValue,
                           range: joint.minValue...joint.maxValue,
                           step: joint.isRevolute ? 1 : 0.01,
                           suffix: joint.unitSuffix) { value in
                    document.setJointValue(joint.pivotPath, value: value)
                }
                .frame(maxWidth: 160)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// A single state button in the joint's segmented switcher — accent-filled when
/// it is the current pose.
struct StateChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(isActive ? Palette.accent.color : Palette.textSecondary.color)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isActive
                        ? Palette.accent.color.opacity(0.18)
                        : (hovering ? Palette.surfaceHover.color : Palette.surfaceSunken.color)))
                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(isActive ? Palette.accent.color.opacity(0.5) : Palette.borderSubtle.color,
                                  lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("joint.state.\(title)")
    }
}
