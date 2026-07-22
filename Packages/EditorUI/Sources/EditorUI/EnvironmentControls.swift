import SwiftUI
import ViewportKit

/// Inspector control strip for the viewport's image-based lighting and
/// background (specs/viewport.md "Environment & Lighting"). All state lives in
/// the pure ``EnvironmentSettings`` value; this view only edits it.
public struct EnvironmentControls: View {

    @Binding var settings: EnvironmentSettings
    /// Invoked when the user asks to load a custom `.hdr`/`.exr`. The host
    /// presents the file picker (kept out of the view so it stays testable);
    /// the returned URL is validated and applied here.
    let onChooseCustomEnvironment: (() -> URL?)?

    public init(settings: Binding<EnvironmentSettings>,
                onChooseCustomEnvironment: (() -> URL?)? = nil) {
        self._settings = settings
        self.onChooseCustomEnvironment = onChooseCustomEnvironment
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            environmentSection
            Divider()
            exposureSection
            Divider()
            backgroundSection
            Divider()
            groundingSection
        }
        .padding(12)
    }

    // MARK: Environment (IBL) source

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment")
                .font(.headline)
            Picker("Preset", selection: presetBinding) {
                ForEach(EnvironmentModel.IBLPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)

            HStack {
                if let url = settings.customEnvironmentURL, settings.usesCustomEnvironment {
                    Label(url.lastPathComponent, systemImage: "photo")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Clear") { settings.clearCustomEnvironment() }
                } else {
                    Button("Load HDR/EXR…") { chooseCustomEnvironment() }
                    Spacer()
                }
            }
            .font(.callout)
        }
    }

    /// The picker edits the preset while dropping any custom override so the
    /// menu selection always matches what is rendering.
    private var presetBinding: Binding<EnvironmentModel.IBLPreset> {
        Binding(
            get: { settings.preset },
            set: { settings.selectPreset($0) })
    }

    func chooseCustomEnvironment() {
        guard let url = onChooseCustomEnvironment?() else { return }
        settings.setCustomEnvironment(url)
    }

    // MARK: Exposure + intensity

    private var exposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exposure")
                Spacer()
                Text(String(format: "%+.1f EV", settings.exposureEV))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: exposureBinding,
                   in: EnvironmentModel.exposureRange)

            HStack {
                Text("Intensity")
                Spacer()
                Text(String(format: "%.2f×", settings.intensity))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: intensityBinding, in: Self.intensitySliderRange)

            Picker("Tone Mapping", selection: toneMappingBinding) {
                ForEach(ToneMapping.allCases) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .pickerStyle(.menu)
        }
        .font(.callout)
    }

    var toneMappingBinding: Binding<ToneMapping> {
        Binding(get: { settings.toneMapping }, set: { settings.toneMapping = $0 })
    }

    static let intensitySliderRange: ClosedRange<Double> =
        Double(EnvironmentModel.intensityRange.lowerBound)...Double(EnvironmentModel.intensityRange.upperBound)

    private var exposureBinding: Binding<Double> {
        Binding(get: { settings.exposureEV }, set: { settings.setExposure(ev: $0) })
    }

    private var intensityBinding: Binding<Double> {
        Binding(get: { Double(settings.intensity) },
                set: { settings.setIntensity(Float($0)) })
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background")
                .font(.headline)
            Picker("Background", selection: backgroundKindBinding) {
                ForEach(BackgroundKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case .solidColor = settings.background {
                ColorPicker("Color", selection: solidColorBinding, supportsOpacity: false)
                    .font(.callout)
            }
        }
    }

    /// The background modes as a plain selectable kind (colour payload is
    /// edited separately via the ColorPicker below). "AR Preview" is the
    /// grounded QuickLook look the contact shadow is gated to (#126).
    enum BackgroundKind: String, CaseIterable, Identifiable {
        case environment, arPreview, color, transparent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .environment: "Environment"
            case .arPreview: "AR Preview"
            case .color: "Color"
            case .transparent: "Transparent"
            }
        }
    }

    var backgroundKindBinding: Binding<BackgroundKind> {
        Binding(
            get: {
                switch settings.background {
                case .environment: .environment
                case .arPreview: .arPreview
                case .solidColor: .color
                case .transparent: .transparent
                }
            },
            set: { kind in
                switch kind {
                case .environment: settings.background = .environment
                case .arPreview: settings.background = .arPreview
                case .transparent: settings.background = .transparent
                case .color:
                    if case .solidColor = settings.background { return }
                    settings.background = .solidColor(SIMD3(0.11, 0.11, 0.13))
                }
            })
    }

    // MARK: Grounding contact shadow (#126)

    private var groundingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Grounding")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: groundingEnabledBinding)
                    .labelsHidden()
            }
            Text(groundingActive
                 ? "Contact shadow matches AR Quick Look."
                 : "Select the AR Preview background to ground the model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Shadow Softness")
                Spacer()
                Text(String(format: "%.0f%%", settings.grounding.softness * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: softnessBinding, in: Self.softnessSliderRange)
                .disabled(!settings.grounding.isEnabled)
        }
        .font(.callout)
    }

    /// Whether a contact shadow is actually being drawn right now (enabled AND
    /// on a grounded background).
    var groundingActive: Bool {
        settings.grounding.isActive(for: settings.background)
    }

    var groundingEnabledBinding: Binding<Bool> {
        Binding(get: { settings.grounding.isEnabled },
                set: { settings.grounding.isEnabled = $0 })
    }

    static let softnessSliderRange: ClosedRange<Double> =
        Double(GroundingSettings.softnessRange.lowerBound)...Double(GroundingSettings.softnessRange.upperBound)

    var softnessBinding: Binding<Double> {
        Binding(get: { Double(settings.grounding.softness) },
                set: { settings.grounding.setSoftness(Float($0)) })
    }

    var solidColorBinding: Binding<Color> {
        Binding(
            get: {
                if case .solidColor(let c) = settings.background {
                    return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                }
                return .black
            },
            set: { color in
                let resolved = color.resolveRGB()
                settings.background = .solidColor(SIMD3(resolved.0, resolved.1, resolved.2))
            })
    }
}

extension Color {
    /// Best-effort sRGB component extraction for persisting a picked colour into
    /// the pure ``EnvironmentSettings`` value.
    func resolveRGB() -> (Float, Float, Float) {
        #if canImport(AppKit)
        if let ns = NSColor(self).usingColorSpace(.sRGB) {
            return (Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
        }
        #endif
        return (0, 0, 0)
    }
}
