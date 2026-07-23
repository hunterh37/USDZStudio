import Foundation
import SculptKit
import EditingKit

/// Bakes a `MaterialSpec`'s procedural `facade` (#147) into albedo + emissive
/// PNGs and returns a material whose `albedoMap`/`emissiveMap` point at them, so
/// the surface pass binds real lit-window detail instead of a flat colour.
///
/// The generation is pure `SculptKit.FacadeTextureGenerator`; only the file
/// write goes through an injected `writer` seam (defaulting to the ImageIO
/// `RasterPNGWriter`) so the path decisions are testable without touching disk.
public enum FacadeBaker {
    /// Signature of the pixel-buffer → file sink.
    public typealias Writer = (RasterImage, URL) throws -> Void

    /// Bake `material.facade` into `directory`, returning the material with map
    /// paths filled in. Returns the material unchanged when it has no facade.
    ///
    /// Existing explicit `albedoMap`/`emissiveMap` on the spec win — a facade
    /// only *fills* an empty channel, never clobbers a hand-authored map.
    public static func bake(
        _ material: MaterialSpec,
        into directory: URL,
        writer: Writer = RasterPNGWriter.write
    ) throws -> MaterialSpec {
        guard let facade = material.facade else { return material }
        let maps = FacadeTextureGenerator.generate(facade)

        var out = material
        let stem = CreateMaterialCommand.sanitizedPrimName(material.id)
        if out.albedoMap == nil {
            let url = directory.appendingPathComponent("\(stem)_facade_albedo.png")
            try writer(maps.albedo, url)
            out.albedoMap = url.path
        }
        if out.emissiveMap == nil {
            let url = directory.appendingPathComponent("\(stem)_facade_emissive.png")
            try writer(maps.emissive, url)
            out.emissiveMap = url.path
        }
        return out
    }

    /// The directory facade textures are baked into for a session: a `textures/`
    /// folder beside the stage file, or a per-session temp folder when the
    /// session is headless (no `sourceURL`).
    public static func bakeDirectory(for sourceURL: URL?) -> URL {
        if let sourceURL {
            return sourceURL.deletingLastPathComponent().appendingPathComponent("textures")
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("usdz-facade-\(UUID().uuidString)")
    }
}
