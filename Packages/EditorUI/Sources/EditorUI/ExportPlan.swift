import Foundation

/// The output formats the one-click / advanced export flow can write. This is
/// the *stage* export path (the live edited scene → a USD file via
/// `StageSaver`), distinct from the Convert flow, which imports foreign formats.
///
/// Pure value type with no UI or I/O so the destination math and format
/// metadata are unit-tested to the module floor; the SwiftUI export views are
/// thin shells over this.
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    /// Packaged, shareable AR archive — the default "grab and send" output.
    case usdz
    /// Human-readable USD text (round-trippable, diff-friendly).
    case usda
    /// Binary crate — compact, faster to open than text.
    case usdc

    public var id: String { rawValue }

    /// File extension written to disk (matches the raw value).
    public var fileExtension: String { rawValue }

    /// Short label for pickers and buttons.
    public var displayName: String {
        switch self {
        case .usdz: return "USDZ"
        case .usda: return "USDA"
        case .usdc: return "USDC"
        }
    }

    /// One-line description of what the format is good for.
    public var detail: String {
        switch self {
        case .usdz: return "Packaged AR archive — best for sharing & AR Quick Look"
        case .usda: return "Human-readable text — best for diffing & inspection"
        case .usdc: return "Binary crate — compact & fast to open"
        }
    }

    /// SF Symbol paired with the format in the UI.
    public var systemImage: String {
        switch self {
        case .usdz: return "shippingbox"
        case .usda: return "doc.plaintext"
        case .usdc: return "cube"
        }
    }

    /// Whether writing this format needs the Python/usd-core bridge. Only the
    /// text `.usda` form is serialized purely in Swift; `.usdc`/`.usdz` require
    /// the bridge executor (see `StageSaver`).
    public var requiresBridge: Bool { self != .usda }
}

/// A resolved export target: where to write and in what format. Produced by the
/// smart-destination math so the one-click button and the advanced panel share
/// one code path.
public struct ExportPlan: Hashable, Sendable {
    public var destination: URL
    public var format: ExportFormat

    public init(destination: URL, format: ExportFormat) {
        self.destination = destination
        self.format = format
    }

    /// Derives the default destination for a one-click export.
    ///
    /// - Writes next to the currently-open file, reusing its base name, so the
    ///   export sits beside the source the user already knows.
    /// - When nothing is open (untitled scene) there is no source directory, so
    ///   it falls back to `fallbackDirectory` (the caller passes the user's
    ///   Desktop) and `untitledBaseName`.
    /// - The extension always matches `format`, so exporting a `model.glb`-derived
    ///   scene as USDZ yields `model.usdz`.
    public static func smartDestination(
        sourceURL: URL?,
        format: ExportFormat,
        fallbackDirectory: URL,
        untitledBaseName: String = "Untitled"
    ) -> URL {
        let directory = sourceURL?.deletingLastPathComponent() ?? fallbackDirectory
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? untitledBaseName
        return directory
            .appendingPathComponent(base)
            .appendingPathExtension(format.fileExtension)
    }

    /// Convenience: the smart plan (destination + format) for a one-click export.
    public static func smart(
        sourceURL: URL?,
        format: ExportFormat,
        fallbackDirectory: URL,
        untitledBaseName: String = "Untitled"
    ) -> ExportPlan {
        ExportPlan(
            destination: smartDestination(
                sourceURL: sourceURL,
                format: format,
                fallbackDirectory: fallbackDirectory,
                untitledBaseName: untitledBaseName),
            format: format)
    }
}
