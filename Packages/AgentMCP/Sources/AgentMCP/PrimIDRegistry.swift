import Foundation
import USDCore

/// Session-stable prim handles (docs/AGENT_MCP_PLAN.md §3 — "Stable prim
/// handles", cinema4d-mcp's GUID-registry idea).
///
/// USD prim paths break on rename/reparent; a long agent session that renames
/// `/Table` mid-build invalidates every path in its context. Every tool
/// accepts either a path or a `primId`; the registry keeps id → path current
/// across renames, reparents, and removals.
public struct PrimIDRegistry: Sendable {
    private var idToPath: [String: PrimPath] = [:]
    private var pathToID: [PrimPath: String] = [:]
    private var nextSerial = 1

    public init() {}

    /// The stable id for a path, minting one on first sight.
    public mutating func id(for path: PrimPath) -> String {
        if let existing = pathToID[path] { return existing }
        let id = "prim-\(nextSerial)"
        nextSerial += 1
        idToPath[id] = path
        pathToID[path] = id
        return id
    }

    /// Resolve a handle previously minted by `id(for:)`.
    public func path(for id: String) -> PrimPath? {
        idToPath[id]
    }

    /// Re-point every handle under `oldPath` to the same subpath under
    /// `newPath` (rename and reparent are both "the subtree moved").
    public mutating func move(from oldPath: PrimPath, to newPath: PrimPath) {
        let affected = pathToID.keys.filter { $0 == oldPath || oldPath.isAncestor(of: $0) }
        for path in affected {
            guard let id = pathToID.removeValue(forKey: path) else { continue }
            let suffix = Array(path.components.dropFirst(oldPath.components.count))
            var moved = newPath
            for name in suffix {
                guard let next = moved.appending(name) else { break }
                moved = next
            }
            idToPath[id] = moved
            pathToID[moved] = id
        }
    }

    /// Drop every handle at or under a removed subtree. Removed ids stay
    /// invalid forever — they are never re-minted for a new prim.
    public mutating func invalidate(subtree path: PrimPath) {
        let affected = pathToID.keys.filter { $0 == path || path.isAncestor(of: $0) }
        for p in affected {
            if let id = pathToID.removeValue(forKey: p) {
                idToPath.removeValue(forKey: id)
            }
        }
    }

    /// All live handles, for `describe_scene` payloads.
    public var handles: [(id: String, path: PrimPath)] {
        idToPath.map { ($0.key, $0.value) }.sorted { $0.path < $1.path }
    }
}
