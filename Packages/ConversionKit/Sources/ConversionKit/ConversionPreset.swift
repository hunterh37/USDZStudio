import Foundation

/// A named bundle of conversion settings. Presets are the shared vocabulary
/// between the conversion sheet UI, the batch engine, and the CLI so a user
/// can say "ecommerce" once and get the same texture policy everywhere.
///
/// A preset is intentionally just a `TexturePolicy` plus identity for now;
/// as the pipeline grows per-stage options (mesh welding, coordinate fixes)
/// they hang off this same struct so callers never learn a second knob.
public struct ConversionPreset: Hashable, Sendable, Identifiable {
    /// Stable machine identifier (also the CLI `--preset` token).
    public let id: String
    /// Human-facing name for menus and logs.
    public let name: String
    /// One-line explanation of the trade-off the preset makes.
    public let summary: String
    /// The texture handling this preset applies.
    public var texturePolicy: TexturePolicy

    public init(id: String, name: String, summary: String, texturePolicy: TexturePolicy) {
        self.id = id
        self.name = name
        self.summary = summary
        self.texturePolicy = texturePolicy
    }
}

extension ConversionPreset {
    /// Small, web-friendly output: aggressively downscaled textures and JPEG
    /// base color to keep delivered file sizes low for online catalogs.
    public static let ecommerce = ConversionPreset(
        id: "ecommerce",
        name: "E-commerce",
        summary: "Small files: 1K textures, JPEG base color.",
        texturePolicy: TexturePolicy(maxSize: 1024, encodeBaseColorAsJPEG: true, jpegQuality: 0.85)
    )

    /// Conservative settings tuned for AR Quick Look: 2K PNG textures, no
    /// lossy base-color re-encode, so material fidelity is preserved.
    public static let quickLookStrict = ConversionPreset(
        id: "quicklook-strict",
        name: "Quick Look (strict)",
        summary: "AR-safe: 2K textures, lossless PNG base color.",
        texturePolicy: TexturePolicy(maxSize: 2048, encodeBaseColorAsJPEG: false, jpegQuality: 0.9)
    )

    /// Archival: never downscale, never re-encode. Largest files, best
    /// fidelity — the source of truth you keep and re-derive from.
    public static let lossless = ConversionPreset(
        id: "lossless",
        name: "Lossless",
        summary: "Archival: full-resolution textures, no re-encode.",
        texturePolicy: TexturePolicy(maxSize: .max, encodeBaseColorAsJPEG: false, jpegQuality: 1.0)
    )

    /// Every built-in preset, in menu order. The default (`quickLookStrict`)
    /// leads because it matches the app's out-of-the-box texture policy.
    public static let builtins: [ConversionPreset] = [.quickLookStrict, .ecommerce, .lossless]

    /// Looks up a preset by its `id` (case-insensitively). Returns `nil` for
    /// unknown tokens so callers can produce a helpful error listing choices.
    public static func named(_ id: String) -> ConversionPreset? {
        builtins.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// The comma-separated list of valid `--preset` tokens, for usage text.
    public static var identifiers: String {
        builtins.map(\.id).joined(separator: ", ")
    }
}
