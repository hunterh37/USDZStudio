import Foundation

/// A script entry in the library panel (specs/scripting.md; console + CLI
/// land in Phase 4 — the model is here so EditorUI can stub the panel).
public struct ScriptEntry: Hashable, Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var isBundled: Bool

    public init(url: URL, isBundled: Bool) {
        self.url = url
        self.isBundled = isBundled
    }

    /// Display name: file name without the .py extension.
    public var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Pure sorting/filtering logic for the script library panel.
public enum ScriptLibrary {

    /// Bundled scripts first, then user scripts, alphabetical within groups.
    public static func sorted(_ entries: [ScriptEntry]) -> [ScriptEntry] {
        entries.sorted {
            if $0.isBundled != $1.isBundled { return $0.isBundled }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Keeps only `.py` files.
    public static func scripts(from urls: [URL], bundled: Bool) -> [ScriptEntry] {
        urls.filter { $0.pathExtension.lowercased() == "py" }
            .map { ScriptEntry(url: $0, isBundled: bundled) }
    }
}
