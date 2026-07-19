import Foundation
import USDCore

/// Error thrown when a mutation targets a prim (or parent) that isn't on the stage.
public enum StageMutationError: Error, Hashable, Sendable, CustomStringConvertible {
    case primNotFound(PrimPath)
    case parentNotFound(PrimPath)
    case invalidName(String)
    case nameCollision(PrimPath)
    case variantSetNotFound(path: PrimPath, setName: String)

    public var description: String {
        switch self {
        case .primNotFound(let p): return "No prim at \(p)"
        case .parentNotFound(let p): return "No parent prim at \(p)"
        case .invalidName(let n): return "Invalid prim name: \(n)"
        case .nameCollision(let p): return "A sibling already exists at \(p)"
        case let .variantSetNotFound(p, s): return "No variant set '\(s)' on \(p)"
        }
    }
}

/// A concrete, value-backed `USDStageMutable`.
///
/// USDBridge remains the source of truth against a real usd-core stage, but the
/// editor, scripting console, and tests need a stage they can mutate without a
/// Python round-trip on every keystroke. `InMemoryStage` applies the full
/// `StageMutation` vocabulary against an in-memory `StageSnapshot`, so commands
/// (and their undo) can be exercised and unit-tested in isolation.
public final class InMemoryStage: USDStageMutable, @unchecked Sendable {
    private var snapshot: StageSnapshot
    private let lock = NSLock()

    public init(_ snapshot: StageSnapshot = StageSnapshot()) {
        self.snapshot = snapshot
    }

    // MARK: USDStageProtocol

    public var sourceURL: URL? { lock.withLock { snapshot.sourceURL } }
    public var metadata: StageMetadata { lock.withLock { snapshot.metadata } }
    public var rootPrims: [Prim] { lock.withLock { snapshot.rootPrims } }

    /// A consistent value-typed copy of the current state.
    public var currentSnapshot: StageSnapshot { lock.withLock { snapshot } }

    // MARK: USDStageMutable

    public func apply(_ mutation: StageMutation) throws {
        try lock.withLock {
            switch mutation {
            case let .setAttribute(path, attribute):
                try mutate(at: path) { prim in
                    if let i = prim.attributes.firstIndex(where: { $0.name == attribute.name }) {
                        prim.attributes[i] = attribute
                    } else {
                        prim.attributes.append(attribute)
                    }
                }
            case let .removeAttribute(path, name):
                try mutate(at: path) { prim in
                    prim.attributes.removeAll { $0.name == name }
                }
            case let .setVisibility(path, visibility):
                try mutate(at: path) { $0.visibility = visibility }
            case let .setActive(path, isActive):
                try mutate(at: path) { $0.isActive = isActive }
            case let .renamePrim(path, newName):
                try rename(at: path, to: newName)
            case let .removePrim(path):
                try remove(at: path)
            case let .insertPrim(parent, index, prim):
                try insert(prim, parent: parent, index: index)
            case let .setStageMetadata(metadata):
                snapshot.metadata = metadata
            case let .setVariantSelection(path, setName, selection):
                try mutate(at: path) { prim in
                    guard let i = prim.variantSets.firstIndex(where: { $0.name == setName }) else {
                        throw StageMutationError.variantSetNotFound(path: path, setName: setName)
                    }
                    prim.variantSets[i].selection = selection
                }
            }
        }
    }

    // MARK: Tree editing (all under lock)

    private func mutate(at path: PrimPath, _ body: (inout Prim) throws -> Void) throws {
        guard try transform(&snapshot.rootPrims, matching: path, body) else {
            throw StageMutationError.primNotFound(path)
        }
    }

    /// Depth-first walk; applies `body` to the prim whose path equals `path`.
    /// Returns `true` if a prim was found and mutated.
    private func transform(_ prims: inout [Prim], matching path: PrimPath, _ body: (inout Prim) throws -> Void) throws -> Bool {
        for i in prims.indices {
            if prims[i].path == path {
                try body(&prims[i])
                return true
            }
            if prims[i].path.isAncestor(of: path) {
                if try transform(&prims[i].children, matching: path, body) { return true }
            }
        }
        return false
    }

    private func rename(at path: PrimPath, to newName: String) throws {
        guard PrimPath.isValidName(newName) else { throw StageMutationError.invalidName(newName) }
        guard let newPath = path.parent.appending(newName) else {
            // coverage:disable — unreachable: appending re-runs the same isValidName predicate the guard above already enforced, so it cannot return nil here.
            throw StageMutationError.invalidName(newName)
        }
        // Sibling collision check.
        let siblings = childList(of: path.parent)
        if siblings.contains(where: { $0.path == newPath }) {
            throw StageMutationError.nameCollision(newPath)
        }
        try mutate(at: path) { prim in
            InMemoryStage.reparentPaths(&prim, to: newPath)
        }
    }

    /// Rewrites `prim.path` to `newPath` and cascades the prefix change through
    /// every descendant so subtree paths stay consistent.
    static func reparentPaths(_ prim: inout Prim, to newPath: PrimPath) {
        prim.path = newPath
        for i in prim.children.indices {
            guard let childNew = newPath.appending(prim.children[i].path.name) else { continue }
            reparentPaths(&prim.children[i], to: childNew)
        }
    }

    private func remove(at path: PrimPath) throws {
        guard removeRecursive(&snapshot.rootPrims, path: path) else {
            throw StageMutationError.primNotFound(path)
        }
    }

    private func removeRecursive(_ prims: inout [Prim], path: PrimPath) -> Bool {
        if let i = prims.firstIndex(where: { $0.path == path }) {
            prims.remove(at: i)
            return true
        }
        for i in prims.indices where prims[i].path.isAncestor(of: path) {
            if removeRecursive(&prims[i].children, path: path) { return true }
        }
        return false
    }

    private func insert(_ prim: Prim, parent: PrimPath?, index: Int) throws {
        guard let parent, !parent.isRoot else {
            snapshot.rootPrims.insert(prim, at: clamp(index, count: snapshot.rootPrims.count))
            return
        }
        guard try transform(&snapshot.rootPrims, matching: parent, { p in
            p.children.insert(prim, at: self.clamp(index, count: p.children.count))
        }) else {
            throw StageMutationError.parentNotFound(parent)
        }
    }

    private func childList(of parent: PrimPath) -> [Prim] {
        if parent.isRoot { return snapshot.rootPrims }
        return snapshot.rootPrims.lazy.compactMap { $0.prim(at: parent) }.first?.children ?? []
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
