import SwiftUI
import USDCore
import EditingKit
import DicyaninDesignSystem

/// The inspector. Read-only surfacing landed in Phase 1; Phase 3 makes the
/// prim, transform, and stage tabs *editable*, routing every change through the
/// document's `CommandStack` so edits are undoable. Material editing stays
/// read-only until its own roadmap slice.
struct InspectorView: View {
    /// nil when no file is open — the tabs then render empty states.
    let document: EditorDocument?

    enum Tab: String, CaseIterable, Identifiable {
        case prim = "Prim"
        case transform = "Transform"
        case material = "Material"
        case stage = "Stage"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .prim

    private var stage: (any USDStageProtocol)? { document?.snapshot }
    private var selection: Selection { document?.selection ?? .empty }

    private var prim: Prim? {
        guard let stage, let path = selection.primary else { return nil }
        return stage.prim(at: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.xs)

            Divider().overlay(Palette.panelBorder.color)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    switch tab {
                    case .prim: primTab
                    case .transform: transformTab
                    case .material: materialTab
                    case .stage: stageTab
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.panelBackground.color)
    }

    // MARK: Prim

    @ViewBuilder
    private var primTab: some View {
        if let document, let prim {
            PanelSection(title: "Prim") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    LabeledField(label: "Name") {
                        NameField(name: prim.name) { document.rename(prim.path, to: $0) }
                    }
                    FieldRow(label: "Path", value: prim.path.description)
                    FieldRow(label: "Type", value: prim.typeName.isEmpty ? "(typeless)" : prim.typeName)
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
            }
            if !prim.metadata.isEmpty {
                PanelSection(title: "Metadata") {
                    ForEach(prim.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        FieldRow(label: k, value: v)
                    }
                }
            }
            attributesSection(prim.attributes)
            if !prim.relationships.isEmpty {
                PanelSection(title: "Relationships") {
                    ForEach(prim.relationships, id: \.name) { rel in
                        FieldRow(label: rel.name,
                                 value: rel.targets.map(\.description).joined(separator: ", "))
                    }
                }
            }
            if !prim.variantSets.isEmpty {
                PanelSection(title: "Variant Sets") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
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
            }
        } else {
            emptyState("No selection")
        }
    }

    @ViewBuilder
    private func attributesSection(_ attributes: [Attribute]) -> some View {
        if !attributes.isEmpty {
            PanelSection(title: "Attributes (\(attributes.count))") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
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

    // MARK: Material (read-only until its own slice)

    @ViewBuilder
    private var materialTab: some View {
        if let prim {
            let binding = prim.relationships.first { $0.name.contains("material:binding") }
            let shaderAttrs = prim.attributes.filter { $0.name.hasPrefix("inputs:") }
            if binding == nil && shaderAttrs.isEmpty {
                emptyState("No material binding or shader inputs on this prim.")
            } else {
                if let binding {
                    PanelSection(title: "Binding") {
                        FieldRow(label: "material", value: binding.targets.map(\.description).joined(separator: ", "))
                    }
                }
                if !shaderAttrs.isEmpty {
                    PanelSection(title: "Shader Inputs") {
                        ForEach(shaderAttrs, id: \.name) { attr in
                            FieldRow(label: attr.name.replacingOccurrences(of: "inputs:", with: ""),
                                     value: ValueFormatter.string(attr.value))
                        }
                    }
                }
            }
        } else {
            emptyState("No selection")
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stageTab: some View {
        if let document, let stage {
            let m = stage.metadata
            PanelSection(title: "Stage") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
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
                        DoubleField(value: m.metersPerUnit) { new in
                            var copy = m; copy.metersPerUnit = new
                            document.setStageMetadata(copy)
                        }
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
            }
            if m.isAnimated {
                PanelSection(title: "Animation") {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        FieldRow(label: "Start", value: m.startTimeCode.map { String(format: "%g", $0) } ?? "—")
                        FieldRow(label: "End", value: m.endTimeCode.map { String(format: "%g", $0) } ?? "—")
                        FieldRow(label: "FPS", value: m.timeCodesPerSecond.map { String(format: "%g", $0) } ?? "—")
                    }
                }
            }
            if !m.customLayerData.isEmpty {
                PanelSection(title: "Custom Layer Data") {
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

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Palette.accent.color.opacity(0.2)))
            .foregroundStyle(Palette.accent.color)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Palette.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editable field building blocks

/// A label + trailing editor laid out like `FieldRow`, for interactive controls.
private struct LabeledField<Content: View>: View {
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
            .textFieldStyle(.roundedBorder)
            .font(.system(size: TypeScale.inspectorField, design: .monospaced))
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

/// A numeric text field committing a Double on submit/blur; reverts on garbage.
private struct DoubleField: View {
    let value: Double
    let commit: (Double) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(value: Double, commit: @escaping (Double) -> Void) {
        self.value = value
        self.commit = commit
        _text = State(initialValue: Self.format(value))
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: TypeScale.inspectorField, design: .monospaced))
            .frame(maxWidth: 90)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commitIfChanged)
            .onChange(of: focused) { _, isFocused in if !isFocused { commitIfChanged() } }
            .onChange(of: value) { _, new in text = Self.format(new) }
    }

    private func commitIfChanged() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = Self.format(value); return
        }
        if parsed != value { commit(parsed) }
    }

    static func format(_ v: Double) -> String { String(format: "%g", v) }
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

/// Editable T/R/S for a prim, committed as one undoable `SetTransformCommand`
/// per field edit. Seeded from the prim's current transform; `.id(path)` in the
/// parent re-seeds it when the selection changes.
private struct TransformEditor: View {
    let document: EditorDocument
    let path: PrimPath

    private let axes = ["X", "Y", "Z"]

    var body: some View {
        let trs = document.transform(at: path)
        VStack(alignment: .leading, spacing: Spacing.lg) {
            vectorSection("Translate", values: trs.translation) { axis, v in
                var next = trs; next.translation[axis] = v
                document.setTransform(path, to: next, verb: "Move")
            }
            vectorSection("Rotate (°)", values: trs.rotationEulerDegrees) { axis, v in
                var next = trs; next.rotationEulerDegrees[axis] = v
                document.setTransform(path, to: next, verb: "Rotate")
            }
            vectorSection("Scale", values: trs.scale) { axis, v in
                var next = trs; next.scale[axis] = v
                document.setTransform(path, to: next, verb: "Scale")
            }
            Button("Reset to identity") {
                document.setTransform(path, to: .identity, verb: "Reset Transform")
            }
            .buttonStyle(.link)
            .font(.system(size: TypeScale.body))
        }
    }

    private func vectorSection(_ title: String, values: [Double],
                               set: @escaping (Int, Double) -> Void) -> some View {
        PanelSection(title: title) {
            HStack(spacing: Spacing.xs) {
                ForEach(axes.indices, id: \.self) { axis in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(axes[axis])
                            .font(.system(size: TypeScale.caption, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary.color)
                        DoubleField(value: values[axis]) { set(axis, $0) }
                    }
                }
            }
        }
    }
}
