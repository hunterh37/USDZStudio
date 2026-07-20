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
public struct EnvironmentSettings: Equatable, Sendable, Codable {

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

    public init(preset: EnvironmentModel.IBLPreset = .studio,
                customEnvironmentURL: URL? = nil,
                exposureEV: Double = 0,
                intensity: Float = 1,
                background: EnvironmentModel.Background = .environment) {
        self.preset = preset
        self.customEnvironmentURL = customEnvironmentURL
        self.exposureEV = min(max(exposureEV, EnvironmentModel.exposureRange.lowerBound),
                              EnvironmentModel.exposureRange.upperBound)
        self.intensity = min(max(intensity, EnvironmentModel.intensityRange.lowerBound),
                             EnvironmentModel.intensityRange.upperBound)
        self.background = background
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
