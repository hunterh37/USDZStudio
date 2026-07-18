import SwiftUI
import AppKit
import USDCore
import EditingKit
import DicyaninDesignSystem

/// The inspector's editable Material tab (Phase 3 — material editing).
///
/// Shows the UsdPreviewSurface inputs of the material bound to the selected
/// prim, following the binding up the namespace so a deep child part shows the
/// material it actually renders with. Every edit commits through the document as
/// one undoable `SetMaterialInputCommand`; slider drags commit once on release
/// rather than flooding the undo stack with intermediate values.
///
/// Inputs the material carries no opinion on are shown at their USD fallback and
/// marked `default`; editing one authors it, and "Revert" clears it back to
/// carrying no opinion (which is *not* the same as authoring the fallback value).
struct MaterialEditor: View {
    let document: EditorDocument
    /// The resolved material: the Material prim plus the prim its inputs live on.
    let material: ResolvedMaterial
    /// The prim the user actually selected — may be a mesh that inherits it.
    let selected: PrimPath

    /// The `diffuseColor` catalog entry — the base albedo a "recolor" targets.
    private var diffuseColor: PreviewSurfaceInput { PreviewSurfaceInput.named("diffuseColor")! }

    /// The prims a model-wide recolor spans: the whole multi-selection, or just
    /// the selected prim when the selection is empty (e.g. driven by the harness).
    private var recolorScope: [PrimPath] {
        document.selection.paths.isEmpty ? [selected] : document.selection.paths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelRecolorSection

            InspectorSection(title: "Binding") {
                FieldRow(label: "material", value: material.material.path.description)
                if material.hasDedicatedShader {
                    FieldRow(label: "surface", value: material.surfacePath.description)
                }
                if material.material.path != selected, !isBoundDirectly {
                    Text("Inherited — bound on an ancestor of \(selected.name).")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }

            InspectorSection(title: "Surface Inputs",
                             subtitle: String(PreviewSurfaceInput.catalog.count)) {
                ForEach(PreviewSurfaceInput.catalog) { input in
                    MaterialInputRow(
                        input: input,
                        authored: document.materialInput(input, on: material),
                        set: { document.setMaterialInput(input, on: material, to: $0) },
                        clear: { document.clearMaterialInput(input, on: material) })
                }
            }
        }
    }

    /// A single colour well that recolors the base albedo of *every* material in
    /// the selected model at once, as one undoable edit. Distinct from the
    /// per-material "Surface Inputs" below, which only touch the bound material.
    @ViewBuilder
    private var modelRecolorSection: some View {
        let materials = document.materials(under: recolorScope)
        if materials.count > 1 {
            InspectorSection(title: "Whole Model") {
                LabeledField(label: "Recolor all") {
                    ColorInputWell(components: representativeDiffuse(materials)) {
                        document.recolorMaterials(materials, input: diffuseColor, to: .vector($0))
                    }
                }
                Text("Sets base colour on all \(materials.count) materials in the "
                     + "selection as one undoable step.")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
    }

    /// The base colour to seed the model-wide well with: the first material's
    /// authored `diffuseColor`, else the USD fallback.
    private func representativeDiffuse(_ materials: [ResolvedMaterial]) -> [Double] {
        for material in materials {
            if case let .vector(v)? = document.materialInput(diffuseColor, on: material), v.count == 3 {
                return v
            }
        }
        if case let .vector(v) = diffuseColor.fallback { return v }
        return [0.18, 0.18, 0.18]
    }

    /// `true` when the selected prim authors the binding itself (rather than
    /// inheriting it from an ancestor).
    private var isBoundDirectly: Bool {
        guard let prim = document.snapshot.prim(at: selected) else { return false }
        return prim.relationships.contains { $0.name == MaterialBinding.key }
            || prim.metadata[MaterialBinding.key] != nil
    }
}

// MARK: - Rows

/// One input row: label, authored/default state, the type-appropriate control,
/// and a revert affordance for authored values.
private struct MaterialInputRow: View {
    let input: PreviewSurfaceInput
    /// The authored value, or `nil` when the material has no opinion.
    let authored: AttributeValue?
    let set: (AttributeValue) -> Void
    let clear: () -> Void

    /// What the control displays: the authored value, else the USD fallback.
    private var value: AttributeValue { authored ?? input.fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                Text(input.name)
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                if authored == nil {
                    Badge("default")
                } else {
                    Button("Revert", action: clear)
                        .buttonStyle(.link)
                        .font(.system(size: TypeScale.caption))
                }
                Spacer(minLength: 0)
            }
            control
                .help(input.summary)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch input.kind {
        case .color:
            ColorInputWell(components: vector) { set(.vector($0)) }
        case let .scalar(range):
            ScalarInputRow(value: scalar, range: range) { set(.double($0)) }
        case .normal:
            VectorInputRow(components: vector) { set(.vector($0)) }
        case let .choice(options):
            Picker("", selection: Binding(
                get: { integer },
                set: { set(.int($0)) })) {
                ForEach(options, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 90)
        }
    }

    // Displayed value, coerced to the shape the control needs. A file carrying a
    // mistyped input falls back to the schema default rather than crashing.
    private var vector: [Double] {
        if case let .vector(v) = value, v.count == 3 { return v }
        if case let .vector(v) = input.fallback { return v }
        return [0, 0, 0]
    }

    private var scalar: Double {
        if case let .double(d) = value { return d }
        if case let .double(d) = input.fallback { return d }
        return 0
    }

    private var integer: Int {
        if case let .int(i) = value { return i }
        if case let .int(i) = input.fallback { return i }
        return 0
    }
}

/// A colour well over a linear `color3f`.
///
/// UsdPreviewSurface colour inputs are **linear**; AppKit hands us sRGB. The
/// conversion happens at this boundary so what the user picks is what they see
/// rendered — authoring the raw sRGB triple into a linear attribute would wash
/// the whole material out.
private struct ColorInputWell: View {
    let components: [Double]
    let commit: ([Double]) -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ColorPicker("", selection: Binding(
                get: { Color(linear: components) },
                set: { picked in
                    guard let linear = picked.linearComponents else { return }
                    commit(linear)
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
            Text(components.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(Palette.textSecondary.color)
        }
    }
}

/// A scalar input as a Blender value slider: range-bounded inputs get the
/// proportional fill bar, and both flavors scrub on drag and edit on click
/// (`ScrubField` commits once per scrub — a single undo entry).
private struct ScalarInputRow: View {
    let value: Double
    let range: ClosedRange<Double>?
    let commit: (Double) -> Void

    var body: some View {
        ScrubField(value: value, range: range, step: scrubStep, commit: commit)
    }

    /// One scrub step spans the range in ~100 steps; unbounded scalars step 0.01.
    private var scrubStep: Double {
        guard let range else { return 0.01 }
        let span = range.upperBound - range.lowerBound
        return span > 0 ? span / 100 : 0.01
    }
}

/// Three axis-tinted scrub fields, stacked, for a `normal3f`-shaped input.
private struct VectorInputRow: View {
    let components: [Double]
    let commit: ([Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(0..<3, id: \.self) { axis in
                ScrubField(value: components[axis],
                           label: axisLabels[axis],
                           labelTint: axisTint(axis),
                           step: 0.01) { new in
                    var next = components
                    next[axis] = new
                    commit(next)
                }
            }
        }
    }
}

// MARK: - Colour space

/// sRGB ⇄ linear transfer functions (IEC 61966-2-1). Phase 4.5 generalises colour
/// management (specs/recoloring.md); this is the minimum correct handling the
/// material tab needs today.
enum SRGBTransfer {
    static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func toSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

private extension Color {
    /// Builds a display colour from a linear `color3f`. Values outside 0…1
    /// (emissive can legitimately exceed 1) are clamped for display only — the
    /// authored attribute keeps its real value.
    init(linear components: [Double]) {
        let srgb = components.map { SRGBTransfer.toSRGB(min(max($0, 0), 1)) }
        self.init(.sRGB, red: srgb[0], green: srgb[1], blue: srgb[2])
    }

    /// The picked colour as linear `color3f` components, or `nil` if AppKit
    /// can't convert it to sRGB.
    var linearComponents: [Double]? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { SRGBTransfer.toLinear(Double($0)) }
    }
}
