import Foundation
import simd

// Pure, GPU-free models for the "what you see is what you ship" render-parity
// feature (GitHub #126, specs/viewport.md "Environment & Lighting"): the
// grounding contact shadow, the QuickLook-matched key/fill directional rig,
// and the tone-mapping curve that maps authored exposure to display. No
// RealityKit types live here, so every decision and every number is
// unit-testable off-GPU; `ViewportPane` turns these values into
// `GroundingShadowComponent`, `DirectionalLightComponent`, and the camera's
// exposure exactly as `EnvironmentModel` is turned into an `EnvironmentResource`.

/// The viewport's grounding contact shadow — the soft shadow a model casts onto
/// the floor it sits on, which is the single biggest cue separating a "floating
/// and flat" preview from AR Quick Look's grounded look.
///
/// Grounding is *viewer state*, never written to the stage, so it is
/// export-profile-neutral. It is meaningful only when the background actually
/// presents a floor (see ``EnvironmentModel/Background/groundsModel``); on a
/// skybox or transparent background there is nothing to catch the shadow, so
/// ``isActive(for:)`` gates it rather than drawing a shadow into the void.
public struct GroundingSettings: Equatable, Sendable, Codable {

    /// Whether the user has grounding enabled at all. Independent of whether it
    /// is *active* — a disabled-but-would-be-grounded state is retained so
    /// toggling backgrounds doesn't silently discard the preference.
    public var isEnabled: Bool

    /// Shadow softness as a fraction (0…1): 0 is a hard contact shadow, 1 the
    /// softest penumbra. Maps to the grounding component's blur in the render
    /// layer; QuickLook uses a fairly soft shadow.
    public var softness: Float

    /// The receiver floor's half-extent as a multiple of the model's bounding
    /// radius, so the shadow catcher always comfortably contains the model
    /// regardless of scene scale. Clamped to a sane range.
    public var groundExtentScale: Float

    /// Softness clamp.
    public static let softnessRange: ClosedRange<Float> = 0...1
    /// Ground-extent clamp (multiples of the model radius).
    public static let groundExtentRange: ClosedRange<Float> = 1...20

    public init(isEnabled: Bool = true,
                softness: Float = 0.7,
                groundExtentScale: Float = 6) {
        self.isEnabled = isEnabled
        self.softness = Self.softnessRange.clamp(softness)
        self.groundExtentScale = Self.groundExtentRange.clamp(groundExtentScale)
    }

    /// Whether a contact shadow should actually be drawn given the active
    /// background: only when the user enabled it *and* the background grounds
    /// the model on a floor.
    public func isActive(for background: EnvironmentModel.Background) -> Bool {
        isEnabled && background.groundsModel
    }

    /// The receiver floor half-extent in world units for a model of the given
    /// bounding radius. A non-positive radius falls back to a unit floor so a
    /// degenerate/empty scene still has a valid catcher.
    public func groundHalfExtent(modelRadius: Float) -> Float {
        let radius = modelRadius > 0 ? modelRadius : 1
        return radius * groundExtentScale
    }

    public mutating func setSoftness(_ value: Float) {
        softness = Self.softnessRange.clamp(value)
    }
}

/// One directional light in the viewport rig, described in pure terms the
/// render layer installs onto a `DirectionalLight`. Direction is the world-space
/// vector the light *travels along* (from the lamp toward the scene).
public struct DirectionalLightSpec: Equatable, Sendable, Codable {

    /// World-space travel direction. Need not be unit length; use
    /// ``normalizedDirection`` when a unit vector is required.
    public var direction: SIMD3<Float>
    /// Illuminance in lux (RealityKit's `DirectionalLightComponent.intensity`).
    public var intensity: Float
    /// Linear-sRGB light colour.
    public var color: SIMD3<Float>
    /// Whether this light casts a shadow (only the key light does by default).
    public var castsShadow: Bool

    public init(direction: SIMD3<Float>,
                intensity: Float,
                color: SIMD3<Float> = SIMD3(repeating: 1),
                castsShadow: Bool = false) {
        self.direction = direction
        self.intensity = max(0, intensity)
        self.color = color
        self.castsShadow = castsShadow
    }

    /// Unit travel direction. A zero/degenerate direction falls back to a
    /// straight-down light so the render layer never gets a NaN basis.
    public var normalizedDirection: SIMD3<Float> {
        let length = simd_length(direction)
        guard length > 1e-6 else { return SIMD3(0, -1, 0) }
        return direction / length
    }
}

/// The three-part lighting rig tuned to match the AR Quick Look look: a shadowed
/// key light, a soft opposing fill that keeps shadowed faces from crushing to
/// black, and the image-based-lighting intensity that supplies ambient and
/// specular. Composed with the already-shipped ``EnvironmentSettings`` IBL
/// source; this rig adds the directional key/fill QuickLook layers on top.
public struct LightingRig: Equatable, Sendable, Codable {

    public var keyLight: DirectionalLightSpec
    public var fillLight: DirectionalLightSpec
    /// Multiplier on the resolved IBL environment's contribution (ambient +
    /// specular). 1 = as-authored.
    public var iblIntensity: Float
    /// Whether the directional key/fill layer is applied at all. When false the
    /// viewport is lit by IBL alone (the pre-#126 behaviour).
    public var isEnabled: Bool

    public static let iblIntensityRange: ClosedRange<Float> = 0...4

    public init(keyLight: DirectionalLightSpec,
                fillLight: DirectionalLightSpec,
                iblIntensity: Float = 1,
                isEnabled: Bool = true) {
        self.keyLight = keyLight
        self.fillLight = fillLight
        self.iblIntensity = Self.iblIntensityRange.clamp(iblIntensity)
        self.isEnabled = isEnabled
    }

    /// The default rig tuned to the QuickLook look: a warm-neutral key from the
    /// upper front-left casting a shadow, a dimmer cool fill from the lower
    /// front-right, both aimed slightly downward toward a grounded model.
    public static let quickLook = LightingRig(
        keyLight: DirectionalLightSpec(
            direction: SIMD3(-0.5, -0.8, -0.6),
            intensity: 3200,
            color: SIMD3(1.0, 0.98, 0.94),
            castsShadow: true),
        fillLight: DirectionalLightSpec(
            direction: SIMD3(0.6, -0.35, 0.5),
            intensity: 900,
            color: SIMD3(0.94, 0.97, 1.0),
            castsShadow: false),
        iblIntensity: 1,
        isEnabled: true)

    public mutating func setIBLIntensity(_ value: Float) {
        iblIntensity = Self.iblIntensityRange.clamp(value)
    }
}

/// The tone-mapping operator applied when converting the linear-light render to
/// the display, so the shipped ``EnvironmentSettings/exposureEV`` maps to a
/// predictable look rather than RealityKit's uncontrolled default. The operators
/// are pure scalar curves — the golden-image harness uses them to predict a
/// reference frame's mapped luminance, and the render layer selects the matching
/// camera tone-map.
public enum ToneMapping: String, CaseIterable, Identifiable, Sendable, Codable {
    /// No curve: linear values clamped to [0,1]. Blows out highlights, matches
    /// nothing photographic — useful as a control.
    case linear
    /// Reinhard `x / (1 + x)`: gentle, never clips, but desaturates highlights.
    case reinhard
    /// ACES-style filmic curve (Narkowicz approximation): the QuickLook-adjacent
    /// default — rolls off highlights with contrast in the mids.
    case aces

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .reinhard: "Reinhard"
        case .aces: "ACES Filmic"
        }
    }

    /// Maps a single non-negative linear-light channel value to a [0,1] display
    /// value under this operator. Negative input is clamped to 0 first.
    public func map(_ x: Float) -> Float {
        let v = max(0, x)
        switch self {
        case .linear:
            return min(1, v)
        case .reinhard:
            return v / (1 + v)
        case .aces:
            // Narkowicz 2015 ACES filmic approximation.
            let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
            let mapped = (v * (a * v + b)) / (v * (c * v + d) + e)
            return min(1, max(0, mapped))
        }
    }

    /// Applies the operator channel-wise to a linear RGB triple.
    public func map(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(map(rgb.x), map(rgb.y), map(rgb.z))
    }
}

extension ClosedRange where Bound: Comparable {
    /// Clamp a value into this range.
    func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
