import SwiftUI
import USDCore
import EditingKit
import ConversionKit
import DicyaninDesignSystem

/// Pure helpers behind the recolor panel — kept out of the view so the
/// colour-math and "what would change" logic is unit-testable.
enum RecolorMath {

    /// sRGB→linear (the inverse of the encode the swatch uses), so a colour
    /// picked in sRGB space is stored as the linear `diffuseColor` USD expects.
    static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// linear→sRGB for display.
    static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func linearize(_ rgb: [Double]) -> [Double] { rgb.map(linearize) }
    static func encode(_ rgb: [Double]) -> [Double] { rgb.map(encode) }

    /// The perceptual CIELAB ΔE76 between two linear-RGB colours — the readout
    /// that tells the user how far a recolor moved the base albedo. Reuses the
    /// shipped, calibrated `ColorManagement` core.
    static func deltaE(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 3, b.count == 3 else { return 0 }
        let la = CIELab(linear: LinearRGB(r: a[0], g: a[1], b: a[2]))
        let lb = CIELab(linear: LinearRGB(r: b[0], g: b[1], b: b[2]))
        return deltaE76(la, lb)
    }
}

/// Stage-wide part recoloring panel (ROADMAP Phase 4.5 / Milestone 6 — the
/// in-app recolor surface). Lists every material in the model with its current
/// base colour and recolors any part — or all parts at once — as undoable edits.
/// Solid-colour path today (the shipped `recolorMaterials`); the perceptual
/// textured path lands with Phase 7 texture-network authoring.
struct RecolorPanel: View {
    let document: EditorDocument?
    let onClose: () -> Void

    /// The bulk target colour (linear), applied to every material by "Recolor All".
    @State private var bulkTarget: [Double] = [0.5, 0.5, 0.5]

    private var materials: [ResolvedMaterial] { document?.allMaterials ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.panelBorder.color)
            content
        }
        .frame(width: 420, height: 480)
        .background(Palette.windowBackground.color)
    }

    private var header: some View {
        HStack {
            Label("Recolor", systemImage: "paintpalette")
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close recolor panel")
        }
        .padding(Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if document == nil {
            centered("Open a document to recolor its materials.")
        } else if materials.isEmpty {
            centered("This model has no editable materials yet. Bind one from the Material inspector, then recolor it here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    bulkSection
                    Divider().overlay(Palette.panelBorder.color)
                    ForEach(materials, id: \.surfacePath) { material in
                        materialRow(material)
                    }
                }
                .padding(Spacing.md)
            }
        }
    }

    /// Recolor-everything control: pick one target and apply it to all materials
    /// as a single undoable step (the "rebrand N SKUs" workflow).
    private var bulkSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("All \(materials.count) material\(materials.count == 1 ? "" : "s")")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Palette.textSecondary.color)
            HStack(spacing: Spacing.sm) {
                swatchPicker(linear: bulkTarget) { bulkTarget = $0 }
                    .accessibilityLabel("Bulk recolor target")
                Button("Recolor All") {
                    document?.recolorMaterials(
                        materials,
                        input: PreviewSurfaceInput.named("diffuseColor")!,
                        to: .vector(bulkTarget))
                }
                .accessibilityHint("Sets the base colour of every material at once as one undoable step.")
                Spacer()
            }
        }
    }

    private func materialRow(_ material: ResolvedMaterial) -> some View {
        let current = document?.diffuseColor(of: material) ?? [0.18, 0.18, 0.18]
        return HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(material.name)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                Text(material.surfacePath.description)
                    .font(.system(size: TypeScale.caption, design: .monospaced))
                    .foregroundStyle(Palette.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.sm)
            swatchPicker(linear: current) { document?.recolor(material, to: $0) }
                .accessibilityLabel("Recolor \(material.name)")
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
    }

    /// A colour well bound in sRGB display space, committing linear components.
    private func swatchPicker(linear: [Double], commit: @escaping ([Double]) -> Void) -> some View {
        ColorPicker("", selection: Binding(
            get: {
                let s = RecolorMath.encode(linear)
                return Color(.sRGB, red: s[0], green: s[1], blue: s[2])
            },
            set: { picked in
                let ns = NSColor(picked).usingColorSpace(.sRGB) ?? NSColor(picked)
                let srgb = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
                commit(RecolorMath.linearize(srgb))
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)
    }

    private func centered(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
                .padding(Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
