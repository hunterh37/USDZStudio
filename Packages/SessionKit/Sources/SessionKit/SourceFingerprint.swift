import Foundation

/// A cheap identity check for the document's backing file: its size and
/// modification date at the moment the session was captured.
///
/// Replaying a write-ahead log onto a file that changed on disk since the
/// session was captured is unsafe (the edits assume the old baseline), so on
/// restore we compare this fingerprint and, on a mismatch, warn in the prompt
/// rather than silently replaying. Size+mtime is deliberately lightweight — we
/// never hash large `.usdz` payloads on the launch path.
public struct SourceFingerprint: Equatable, Codable, Sendable {
    public var size: Int64
    public var modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }

    /// Reads the fingerprint of the file at `url`. Throws
    /// ``SessionError/unreadableSource`` when its attributes can't be read
    /// (e.g. the file no longer exists).
    public static func make(for url: URL) throws -> SourceFingerprint {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw SessionError.unreadableSource
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
        return SourceFingerprint(size: size, modified: modified)
    }

    /// Whether the file at `url` still matches this fingerprint. Any read
    /// failure counts as a mismatch (the safe default — prompt the user).
    public func matches(fileAt url: URL) -> Bool {
        guard let current = try? SourceFingerprint.make(for: url) else { return false }
        return current == self
    }
}
