import SwiftUI
import MeshKit
import DicyaninDesignSystem

// coverage:disable — SwiftUI view body; behavior lives in EditorDocument+Lattice
// (unit-tested in LatticeModeTests). Rendering is exercised by the editor harness.

/// Viewport overlay for lattice (FFD) deform mode (specs/mesh-editing.md
/// §Lattice deformer). Shows the mode badge and the cage controls: per-axis
/// resolution steppers, interpolation basis, an "affect outside" toggle, and
/// Reset / Apply / Cancel. The cage handles themselves are drawn by the
/// viewport's `LatticeCageGizmo`; this is the parameter HUD around it.
public struct LatticeOverlay: View {
    @Bindable var document: EditorDocument

    public init(document: EditorDocument) { self.document = document }

    public var body: some View {
        if let state = document.latticeEdit {
            VStack {
                header(state)
                Spacer()
                controls(state)
            }
            .padding(Spacing.md)
            .background(shortcutHandler)
        }
    }

    private func header(_ state: LatticeEditState) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(Palette.warning.color).frame(width: 7, height: 7)
            Text("LATTICE")
                .font(.system(size: TypeScale.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Palette.warning.color)
            Text("— \(state.path.name)")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(.black.opacity(0.5)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controls(_ state: LatticeEditState) -> some View {
        HStack(spacing: Spacing.md) {
            resolutionSteppers(state)
            interpolationPicker(state)
            affectOutsideToggle(state)
            Divider().frame(height: 20)
            Button("Reset") { document.resetLattice() }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("lattice.reset")
            Button("Apply") { document.exitLatticeMode(commit: true) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!state.isDeformed)
                .accessibilityIdentifier("lattice.apply")
            Button("Cancel") { document.exitLatticeMode(commit: false) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("lattice.cancel")
        }
        .padding(Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(.black.opacity(0.5)))
    }

    private func resolutionSteppers(_ state: LatticeEditState) -> some View {
        let r = state.cage.resolution
        return HStack(spacing: Spacing.xs) {
            Text("Res").font(.system(size: TypeScale.label))
                .foregroundStyle(Palette.textSecondary.color)
            axisStepper("L", value: r.l) { setResolution(l: $0) }
            axisStepper("M", value: r.m) { setResolution(m: $0) }
            axisStepper("N", value: r.n) { setResolution(n: $0) }
        }
    }

    private func axisStepper(_ label: String, value: Int,
                             set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 1) {
            Text("\(label)\(value)").font(.system(size: TypeScale.label, design: .monospaced))
                .frame(width: 30)
            Stepper(label, value: Binding(get: { value }, set: { set($0) }),
                    in: 2...LatticeCage.maxPerAxis)
                .labelsHidden()
        }
        .accessibilityIdentifier("lattice.res.\(label.lowercased())")
    }

    private func interpolationPicker(_ state: LatticeEditState) -> some View {
        HStack(spacing: 2) {
            ForEach(LatticeCage.Interpolation.allCases, id: \.self) { mode in
                let active = state.cage.interpolation == mode
                Button(mode.overlayLabel) { document.setLatticeInterpolation(mode) }
                    .font(.system(size: TypeScale.label))
                    .padding(.horizontal, Spacing.xs).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(active ? Palette.accent.color.opacity(0.3) : .clear))
                    .foregroundStyle(active ? Palette.accent.color : Palette.textSecondary.color)
                    .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("lattice.interpolation")
    }

    private func affectOutsideToggle(_ state: LatticeEditState) -> some View {
        Button {
            document.setLatticeAffectOutside(!state.cage.affectOutside)
        } label: {
            Label("Outside", systemImage: state.cage.affectOutside ? "checkmark.square" : "square")
                .font(.system(size: TypeScale.label))
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.cage.affectOutside ? Palette.accent.color : Palette.textSecondary.color)
        .accessibilityIdentifier("lattice.affectOutside")
    }

    // Convenience: change one axis, keeping the others.
    private func setResolution(l: Int? = nil, m: Int? = nil, n: Int? = nil) {
        guard let r = document.latticeEdit?.cage.resolution else { return }
        document.setLatticeResolution(l: l ?? r.l, m: m ?? r.m, n: n ?? r.n)
    }

    private var shortcutHandler: some View {
        Button("") { document.exitLatticeMode(commit: false) }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0).frame(width: 0, height: 0)
    }
}

extension LatticeCage.Interpolation {
    /// Short overlay label for the interpolation basis picker.
    var overlayLabel: String {
        switch self {
        case .trilinear: return "Linear"
        case .cubicBSpline: return "Cubic"
        }
    }
}

// coverage:enable
