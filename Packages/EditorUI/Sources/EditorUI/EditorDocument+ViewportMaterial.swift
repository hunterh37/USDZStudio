import USDCore
import EditingKit
import ViewportKit
import simd

/// Bridges authored UsdPreviewSurface material values to the viewport, so
/// recolour and other surface-input edits render live on the file-loaded model
/// rather than only in the inspector.
extension EditorDocument {

    /// The UsdPreviewSurface inputs mirrored into the RealityKit viewport. Kept
    /// small and deliberate: the base PBR channels a `PhysicallyBasedMaterial`
    /// can carry faithfully.
    private static let mirroredColorInputs = ["diffuseColor", "emissiveColor"]
    private static let mirroredScalarInputs = ["roughness", "metallic", "opacity"]

    /// A material override for every renderable prim whose bound material the
    /// user has given *plain* (non-textured) surface inputs — keyed by the mesh
    /// prim's absolute path, which is how the viewport locates its entity.
    ///
    /// A material is mirrored only when at least one of its mirrored inputs is
    /// authored as a plain value on the stage. This is intentional: an untouched
    /// (or texture-driven) material carries no such plain opinion, so the loader
    /// keeps its original high-fidelity material — the override never flattens a
    /// material the user didn't edit. Cached per `revision` so repeated SwiftUI
    /// reads don't re-walk the stage.
    public var viewportMaterialOverrides: [String: MaterialOverride] {
        let rev = revision  // read the tracked property so views refresh on edits
        if materialOverrideCacheRevision != rev {
            materialOverrideCache = computeMaterialOverrides()
            materialOverrideCacheRevision = rev
        }
        return materialOverrideCache
    }

    private func computeMaterialOverrides() -> [String: MaterialOverride] {
        var result: [String: MaterialOverride] = [:]
        for prim in snapshot.allPrims() where prim.typeName == "Mesh" {
            guard let material = MaterialBinding.resolve(for: prim.path, in: snapshot),
                  hasMirroredOpinion(material) else { continue }
            result[prim.path.description] = override(from: material)
        }
        return result
    }

    /// `true` when the material's surface carries a plain authored value for any
    /// mirrored input — the signal that the user (or importer) set a flat colour
    /// we can faithfully reproduce, rather than a texture connection we can't.
    private func hasMirroredOpinion(_ material: ResolvedMaterial) -> Bool {
        let names = Self.mirroredColorInputs + Self.mirroredScalarInputs
        return names.contains { name in
            guard let input = PreviewSurfaceInput.named(name) else { return false }
            return materialInput(input, on: material) != nil
        }
    }

    private func override(from material: ResolvedMaterial) -> MaterialOverride {
        MaterialOverride(
            baseColor: color("diffuseColor", on: material),
            emissiveColor: color("emissiveColor", on: material),
            roughness: scalar("roughness", on: material),
            metallic: scalar("metallic", on: material),
            opacity: scalar("opacity", on: material))
    }

    /// A mirrored colour input as sRGB components (authored value, else the USD
    /// fallback). USD `color3f` is linear; the viewport wants display sRGB, so
    /// the transfer happens here — the same conversion the inspector's colour
    /// well uses, so on-screen and rendered colours agree.
    private func color(_ name: String, on material: ResolvedMaterial) -> SIMD3<Float> {
        guard let input = PreviewSurfaceInput.named(name) else { return .zero }
        let linear = vectorValue(materialInput(input, on: material) ?? input.fallback)
        let srgb = linear.map { SRGBTransfer.toSRGB(min(max($0, 0), 1)) }
        return SIMD3(Float(srgb[0]), Float(srgb[1]), Float(srgb[2]))
    }

    private func scalar(_ name: String, on material: ResolvedMaterial) -> Float {
        guard let input = PreviewSurfaceInput.named(name) else { return 0 }
        if case let .double(d) = (materialInput(input, on: material) ?? input.fallback) {
            return Float(d)
        }
        return 0
    }

    private func vectorValue(_ value: AttributeValue) -> [Double] {
        if case let .vector(v) = value, v.count == 3 { return v }
        return [0, 0, 0]
    }
}
