import Foundation

/// A durable reference to the document's backing file, resilient to the file
/// being moved between launches.
///
/// It stores both a bookmark (which survives a rename/move) and the absolute
/// path (a human-readable fallback and what we show in the restore prompt).
/// Resolution prefers the bookmark and falls back to the path, so a stale or
/// unreadable bookmark still restores as long as the file is where it was.
///
/// The app is unsandboxed (specs/architecture.md — no App Store / entitlement
/// constraints), so a plain (non-security-scoped) bookmark is sufficient.
public struct SourceReference: Equatable, Codable, Sendable {
    /// `URL.bookmarkData()` for the file, if it could be created.
    public var bookmark: Data?
    /// The absolute path at capture time — fallback and display value.
    public var path: String?

    public init(bookmark: Data?, path: String?) {
        self.bookmark = bookmark
        self.path = path
    }

    /// Captures a reference to `url`, recording a bookmark when possible.
    public init(url: URL) {
        self.bookmark = try? url.bookmarkData()
        self.path = url.standardizedFileURL.path
    }

    /// Resolves back to a file URL: the bookmark first, then the stored path.
    /// Returns `nil` when neither yields a usable URL.
    public func resolve() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if let path {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// A short display name for the restore prompt ("Restore Robot.usdz?").
    public var displayName: String? {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
