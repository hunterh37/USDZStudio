import Foundation
import USDCore

/// The editor's selection: an ordered set of prim paths
/// (multi-select comes free; part-level selection semantics per PRD §5.3).
public struct Selection: Hashable, Sendable {
    public private(set) var paths: [PrimPath]

    public init(_ paths: [PrimPath] = []) {
        var seen = Set<PrimPath>()
        self.paths = paths.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { paths.isEmpty }
    public var primary: PrimPath? { paths.first }

    public func contains(_ path: PrimPath) -> Bool { paths.contains(path) }

    public func selecting(_ path: PrimPath, additive: Bool = false) -> Selection {
        if additive {
            return contains(path)
                ? Selection(paths.filter { $0 != path })   // ⇧-click toggles
                : Selection(paths + [path])
        }
        return Selection([path])
    }

    public static let empty = Selection()
}

/// Pure outliner presentation logic: flattening the prim tree into rows and
/// filtering by search text (specs/editor-ui.md; virtualization is Phase 5).
public enum OutlinerModel {

    public struct Row: Hashable, Sendable, Identifiable {
        public var id: PrimPath { path }
        public var path: PrimPath
        public var typeName: String
        public var depth: Int
        public var visibility: Visibility
        public var isActive: Bool
        public var hasChildren: Bool
    }

    /// Flattens root prims depth-first into indentable rows, skipping the
    /// subtrees of any path in `collapsed`.
    public static func rows(
        for stage: any USDStageProtocol,
        collapsed: Set<PrimPath> = []
    ) -> [Row] {
        var result: [Row] = []
        func walk(_ prim: Prim) {
            result.append(Row(
                path: prim.path,
                typeName: prim.typeName,
                depth: prim.path.depth - 1,
                visibility: prim.visibility,
                isActive: prim.isActive,
                hasChildren: !prim.children.isEmpty))
            guard !collapsed.contains(prim.path) else { return }
            prim.children.forEach(walk)
        }
        stage.rootPrims.forEach(walk)
        return result
    }

    /// Case-insensitive name/type filter. Matching rows keep their ancestor
    /// rows so the hierarchy stays readable.
    public static func filtered(_ rows: [Row], searchText: String) -> [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        let matches = rows.filter {
            $0.path.name.localizedCaseInsensitiveContains(query)
                || $0.typeName.localizedCaseInsensitiveContains(query)
        }
        var keep = Set<PrimPath>()
        for row in matches {
            var path = row.path
            while !path.isRoot {
                keep.insert(path)
                path = path.parent
            }
        }
        return rows.filter { keep.contains($0.path) }
    }
}
