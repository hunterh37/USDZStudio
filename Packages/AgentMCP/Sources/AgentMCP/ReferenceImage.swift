import Foundation

/// A reference image the agent is working from, surfaced in the editor's
/// reference panel above the inspector. Only a file path plus an optional
/// caption — the image bytes stay on disk; the app loads them for display.
///
/// This value doubles as the on-disk hand-off record (`reference.json`): an
/// image set before the editor window exists (an agent- or CLI-driven launch)
/// is picked up when the app starts. AgentMCP owns the type and its
/// (de)serialization but deliberately not the *location* — callers (App, CLI)
/// supply the directory, keeping this package free of app-support-path
/// knowledge (specs/agent-live-editing.md).
public struct ReferenceImage: Codable, Sendable, Equatable {
    /// Absolute path to the image file on disk.
    public var path: String
    /// Optional short caption shown under the image.
    public var caption: String?

    public init(path: String, caption: String? = nil) {
        self.path = path
        self.caption = caption
    }

    /// JSON payload for tool results and the `usd://reference` resource.
    public var asJSON: JSONValue {
        .object([
            "path": .string(path),
            "caption": caption.map { .string($0) } ?? .null,
        ])
    }

    // MARK: - Disk hand-off (reference.json)

    /// Decode a hand-off record; nil when the file is absent or malformed.
    public static func read(from url: URL) -> ReferenceImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReferenceImage.self, from: data)
    }

    /// Write this record atomically, creating the enclosing directory.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Remove any hand-off record at `url` (a no-op when absent).
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
