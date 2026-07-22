import Foundation
import simd

/// Pure, testable model of the viewport's image-based lighting and background
/// (specs/viewport.md "Environment & Lighting"). Holds no RealityKit types so
/// it can be unit-tested off-GPU; the ViewportPane layer turns an
/// ``EnvironmentSettings`` value into an `EnvironmentResource` + background.
public enum EnvironmentModel {

    /// Bundled image-based-lighting presets (specs/viewport.md: studio,
    /// outdoor, neutral gray, pure white). Each maps to a resource base name
    /// the rendering layer resolves against the app/package bundle.
    public enum IBLPreset: String, CaseIterable, Identifiable, Sendable, Codable {
        case studio, outdoor, neutralGray, pureWhite

        public var id: String { rawValue }

        /// Menu label.
        public var displayName: String {
            switch self {
            case .studio: "Studio"
            case .outdoor: "Outdoor"
            case .neutralGray: "Neutral Gray"
            case .pureWhite: "Pure White"
            }
        }

        /// Base name (no extension) of the bundled `.exr`/`.hdr` the rendering
        /// layer loads for this preset.
        public var resourceName: String {
            switch self {
            case .studio: "ibl_studio"
            case .outdoor: "ibl_outdoor"
            case .neutralGray: "ibl_neutral_gray"
            case .pureWhite: "ibl_pure_white"
            }
        }

        /// The two flat presets need no HDR image — they light the scene from a
        /// constant colour, so the rendering layer can synthesize them instead
        /// of shipping an image file.
        public var constantColor: SIMD3<Float>? {
            switch self {
            case .neutralGray: SIMD3(repeating: 0.5)
            case .pureWhite: SIMD3(repeating: 1)
            case .studio, .outdoor: nil
            }
        }
    }

    /// What fills the viewport behind the model.
    public enum Background: Equatable, Sendable, Codable {
        /// Show the lit environment (skybox) itself.
        case environment
        /// A flat sRGB colour.
        case solidColor(SIMD3<Float>)
        /// The transparent checkerboard (alpha preview).
        case transparent
        /// The AR Quick Look preview look: the model sits on a neutral studio
        /// floor that receives a contact shadow, over a soft graduated backdrop.
        /// This is the background the grounding contact shadow is gated to —
        /// a floating model on a skybox has no floor to catch a shadow, so
        /// grounding only makes sense here (specs/viewport.md "Environment").
        case arPreview

        /// True when this background presents the model as *grounded* on a
        /// floor — the precondition for drawing a contact shadow. Only the
        /// AR-preview backdrop does; every other mode floats the model.
        public var groundsModel: Bool {
            self == .arPreview
        }
    }

    /// The resolved lighting source the rendering layer should install.
    public enum Source: Equatable, Sendable {
        /// A bundled preset backed by an HDR image.
        case presetImage(String)
        /// A bundled preset synthesized from a constant colour.
        case constantColor(SIMD3<Float>)
        /// A user-supplied `.hdr`/`.exr` file.
        case customFile(URL)
    }

    /// File extensions accepted for drag-in custom environments.
    public static let supportedFileExtensions: Set<String> = ["hdr", "exr"]

    /// Exposure is authored in EV stops; this is the clamp range the UI slider
    /// and any programmatic setter honour.
    public static let exposureRange: ClosedRange<Double> = -8...8

    /// Environment intensity multiplier clamp (0 = dark, 1 = as-authored).
    public static let intensityRange: ClosedRange<Float> = 0...4

    /// True when `url` is a file the viewport can load as a custom environment.
    public static func isSupportedEnvironmentFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Converts an EV exposure stop to a linear scene-intensity multiplier
    /// (`2^EV`). Out-of-range EV is clamped first so callers can pass raw
    /// slider values.
    public static func exposureMultiplier(ev: Double) -> Double {
        let clamped = min(max(ev, exposureRange.lowerBound), exposureRange.upperBound)
        return pow(2, clamped)
    }
}

/// The full, serializable environment/lighting state for one viewport.
public struct EnvironmentSettings: Equatable, Sendable {

    /// Active bundled preset. Ignored while a valid ``customEnvironmentURL`` is
    /// set, but retained so clearing the custom file restores the last preset.
    public var preset: EnvironmentModel.IBLPreset

    /// User-supplied `.hdr`/`.exr`. When present and supported it overrides
    /// ``preset`` as the lighting source.
    public var customEnvironmentURL: URL?

    /// Exposure in EV stops (see ``EnvironmentModel/exposureRange``).
    public var exposureEV: Double

    /// Environment lighting intensity multiplier
    /// (see ``EnvironmentModel/intensityRange``).
    public var intensity: Float

    /// What fills the viewport behind the model.
    public var background: EnvironmentModel.Background

    /// Grounding contact-shadow state (#126). Viewer-only; gated to a grounded
    /// background via ``GroundingSettings/isActive(for:)``.
    public var grounding: GroundingSettings

    /// QuickLook-matched key/fill directional rig (#126), composed on top of
    /// the resolved IBL source.
    public var lighting: LightingRig

    /// Tone-mapping operator applied to the linear-light render (#126) so
    /// authored exposure maps predictably.
    public var toneMapping: ToneMapping

    public init(preset: EnvironmentModel.IBLPreset = .studio,
                customEnvironmentURL: URL? = nil,
                exposureEV: Double = 0,
                intensity: Float = 1,
                background: EnvironmentModel.Background = .environment,
                grounding: GroundingSettings = GroundingSettings(),
                lighting: LightingRig = .quickLook,
                toneMapping: ToneMapping = .aces) {
        self.preset = preset
        self.customEnvironmentURL = customEnvironmentURL
        self.exposureEV = min(max(exposureEV, EnvironmentModel.exposureRange.lowerBound),
                              EnvironmentModel.exposureRange.upperBound)
        self.intensity = min(max(intensity, EnvironmentModel.intensityRange.lowerBound),
                             EnvironmentModel.intensityRange.upperBound)
        self.background = background
        self.grounding = grounding
        self.lighting = lighting
        self.toneMapping = toneMapping
    }

    /// The linear intensity multiplier the exposure stop resolves to.
    public var exposureMultiplier: Double {
        EnvironmentModel.exposureMultiplier(ev: exposureEV)
    }

    /// True when a usable custom environment file is set.
    public var usesCustomEnvironment: Bool {
        guard let url = customEnvironmentURL else { return false }
        return EnvironmentModel.isSupportedEnvironmentFile(url)
    }

    /// The lighting source the rendering layer should install: the custom file
    /// if one is set and supported, otherwise the active preset (as an image or
    /// a synthesized constant colour).
    public var resolvedSource: EnvironmentModel.Source {
        if let url = customEnvironmentURL, EnvironmentModel.isSupportedEnvironmentFile(url) {
            return .customFile(url)
        }
        if let color = preset.constantColor {
            return .constantColor(color)
        }
        return .presetImage(preset.resourceName)
    }

    /// Selects a bundled preset and drops any custom environment override.
    public mutating func selectPreset(_ preset: EnvironmentModel.IBLPreset) {
        self.preset = preset
        customEnvironmentURL = nil
    }

    /// Sets a custom environment file if it is a supported type; returns
    /// whether it was accepted. Unsupported files leave state untouched.
    @discardableResult
    public mutating func setCustomEnvironment(_ url: URL) -> Bool {
        guard EnvironmentModel.isSupportedEnvironmentFile(url) else { return false }
        customEnvironmentURL = url
        return true
    }

    /// Clears any custom environment, falling back to the retained preset.
    public mutating func clearCustomEnvironment() {
        customEnvironmentURL = nil
    }

    /// Sets exposure, clamped to ``EnvironmentModel/exposureRange``.
    public mutating func setExposure(ev: Double) {
        exposureEV = min(max(ev, EnvironmentModel.exposureRange.lowerBound),
                         EnvironmentModel.exposureRange.upperBound)
    }

    /// Sets intensity, clamped to ``EnvironmentModel/intensityRange``.
    public mutating func setIntensity(_ value: Float) {
        intensity = min(max(value, EnvironmentModel.intensityRange.lowerBound),
                        EnvironmentModel.intensityRange.upperBound)
    }
}

// Hand-written Codable so the #126 fields (grounding/lighting/toneMapping) are
// optional on decode: settings persisted before this feature landed decode
// cleanly onto their defaults rather than failing the whole value.
extension EnvironmentSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case preset, customEnvironmentURL, exposureEV, intensity, background
        case grounding, lighting, toneMapping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: try c.decodeIfPresent(EnvironmentModel.IBLPreset.self, forKey: .preset) ?? .studio,
            customEnvironmentURL: try c.decodeIfPresent(URL.self, forKey: .customEnvironmentURL),
            exposureEV: try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0,
            intensity: try c.decodeIfPresent(Float.self, forKey: .intensity) ?? 1,
            background: try c.decodeIfPresent(EnvironmentModel.Background.self, forKey: .background) ?? .environment,
            grounding: try c.decodeIfPresent(GroundingSettings.self, forKey: .grounding) ?? GroundingSettings(),
            lighting: try c.decodeIfPresent(LightingRig.self, forKey: .lighting) ?? .quickLook,
            toneMapping: try c.decodeIfPresent(ToneMapping.self, forKey: .toneMapping) ?? .aces)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encodeIfPresent(customEnvironmentURL, forKey: .customEnvironmentURL)
        try c.encode(exposureEV, forKey: .exposureEV)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(background, forKey: .background)
        try c.encode(grounding, forKey: .grounding)
        try c.encode(lighting, forKey: .lighting)
        try c.encode(toneMapping, forKey: .toneMapping)
    }
}
