import Foundation
import USDCore

/// Path-rewriting helpers for grafting prim subtrees between stages
/// (asset import, isolated renders, script re-import).
enum PrimTree {

    /// A copy of `prim` re-rooted at `newPath`, all descendant paths rewritten.
    static func rewritten(_ prim: Prim, to newPath: PrimPath) -> Prim {
        var copy = prim
        rewrite(&copy, to: newPath)
        return copy
    }

    private static func rewrite(_ prim: inout Prim, to newPath: PrimPath) {
        prim.path = newPath
        for i in prim.children.indices {
            if let childPath = newPath.appending(prim.children[i].name) {
                rewrite(&prim.children[i], to: childPath)
            }
        }
    }

    /// A container name that doesn't collide with existing root prims.
    static func availableRootName(base: String, existing: [Prim]) -> String {
        let names = Set(existing.map(\.name))
        let sanitized = PrimPath.sanitizedName(from: base)
        if !names.contains(sanitized) { return sanitized }
        var index = 2
        while names.contains("\(sanitized)_\(index)") { index += 1 }
        return "\(sanitized)_\(index)"
    }
}
