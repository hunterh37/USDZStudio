import Foundation
import simd

/// A resolved UsdPreviewSurface material for one renderable prim, reduced to the
/// display-ready values the viewport applies onto the file-loaded RealityKit
/// entity — so material edits (recolour, roughness, metallic, opacity…) show
/// without reloading the file.
///
/// Colours are **sRGB, 0…1** — the document converts them out of USD's linear
/// `color3f` space (matching the inspector's colour wells) so the RealityKit
/// layer can hand them straight to `NSColor(srgbRed:…)`.
///
/// Pure data, no RealityKit dependency, so it is available on every platform
/// (the coordinator that consumes it is macOS-only).
public struct MaterialOverride: Equatable, Sendable {
    /// Base albedo (`diffuseColor`).
    public var baseColor: SIMD3<Float>
    /// Emitted colour (`emissiveColor`); `.zero` = non-emissive.
    public var emissiveColor: SIMD3<Float>
    public var roughness: Float
    public var metallic: Float
    /// 1 = opaque; below 1 the material renders translucent.
    public var opacity: Float

    public init(baseColor: SIMD3<Float>, emissiveColor: SIMD3<Float> = .zero,
                roughness: Float = 0.5, metallic: Float = 0, opacity: Float = 1) {
        self.baseColor = baseColor
        self.emissiveColor = emissiveColor
        self.roughness = roughness
        self.metallic = metallic
        self.opacity = opacity
    }
}
