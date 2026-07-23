import Foundation

/// The glTF 2.0 compression extensions the native importer can decode on
/// import (specs/conversion-pipeline.md — the `decode-compressed` stage).
///
/// These three are the *default* delivery encodings in Khronos' Asset
/// Creation Guidelines 2.0, so a credible converter must ingest them. Decode
/// is one-way for the `arkit` profile: compressed in → plain geometry +
/// PNG/JPEG textures out. Re-compression on *export* is a separate Phase 7
/// concern and deliberately out of scope here.
public enum CompressionExtension: String, CaseIterable, Sendable {
    /// Geometry compression (`primitive.extensions`). Decoded per-primitive.
    case draco = "KHR_draco_mesh_compression"
    /// Universal texture compression (`texture.extensions`). Transcoded to
    /// RGBA8 then re-encoded to PNG/JPEG by the existing texture stage.
    case textureBasisu = "KHR_texture_basisu"
    /// Buffer-view stream compression (`bufferView.extensions`). Decoded to
    /// plain bytes *before* Draco/accessor interpretation.
    case meshopt = "EXT_meshopt_compression"

    /// Every extension name the importer decodes, for fast membership tests.
    public static let decodableNames: Set<String> = Set(allCases.map(\.rawValue))

    /// Material/feature extensions the importer already tolerates by ignoring
    /// (they degrade to base PBR). Listing a *required* one is still an error —
    /// requiring an extension we ignore would silently change the asset — but
    /// these are called out so the unsupported-extension diagnostic is precise.
    public static let toleratedNames: Set<String> = [
        "KHR_materials_unlit",
        "KHR_materials_emissive_strength",
        "KHR_texture_transform",
    ]
}

/// Classifies a glTF asset's declared extensions into what the importer will
/// decode, what it tolerates by ignoring, and what it cannot honor.
///
/// Pure value-in/value-out so the routing policy is 100% unit-testable without
/// any codec or file I/O. The importer calls `classify` once up front and acts
/// on the result: throw for an unsupported *required* extension, decode the
/// decodable ones, warn for tolerated/used-only ones.
public struct ExtensionClassification: Equatable, Sendable {
    /// Decodable extensions actually present in `extensionsUsed`/`Required`.
    public var decodable: [CompressionExtension]
    /// Extensions listed in `extensionsRequired` that we cannot decode and do
    /// not tolerate — a hard error; the asset would be misrepresented.
    public var unsupportedRequired: [String]
    /// Extensions present but neither decodable nor required — content is
    /// authored without them; surfaced as warnings, never a silent drop.
    public var ignoredUsed: [String]

    /// Classifies the two extension lists. Order is deterministic (the input
    /// order is preserved) so diagnostics and decode ordering are stable.
    public static func classify(
        used: [String]?,
        required: [String]?
    ) -> ExtensionClassification {
        let usedList = used ?? []
        let requiredSet = Set(required ?? [])

        // A required extension not present in `used` is still binding: glTF
        // requires `extensionsRequired ⊆ extensionsUsed`, but we defend against
        // non-conformant assets by unioning both, preserving first-seen order.
        var ordered: [String] = []
        var seen = Set<String>()
        for name in usedList + (required ?? []) where seen.insert(name).inserted {
            ordered.append(name)
        }

        var decodable: [CompressionExtension] = []
        var unsupportedRequired: [String] = []
        var ignoredUsed: [String] = []

        for name in ordered {
            if let ext = CompressionExtension(rawValue: name) {
                decodable.append(ext)
            } else if requiredSet.contains(name) {
                unsupportedRequired.append(name)
            } else {
                ignoredUsed.append(name)
            }
        }
        return ExtensionClassification(
            decodable: decodable,
            unsupportedRequired: unsupportedRequired,
            ignoredUsed: ignoredUsed
        )
    }
}
