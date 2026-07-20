import USDCore

/// Isolate mode — a **non-dirtying session overlay** (ROADMAP Milestone 3;
/// specs/editing-model.md mutation rule 1: "session layer reserved for view-only
/// state like isolate/visibility-preview").
///
/// Isolating a set of prims focuses the viewport on them: everything off their
/// lineage is hidden *for viewing only*. Crucially this authors **nothing** to
/// the root layer — no `EditCommand`, no `visibility` opinion, no dirty flag.
/// `IsolationState` is a pure value the viewport consults to decide what to
/// draw; the round-trip invariant (isolate → exit leaves the stage byte-identical)
/// falls out of the fact that it never touches the stage at all.
public struct IsolationState: Hashable, Sendable {

    /// The isolation roots. Normalized so no root is a descendant of another and
    /// the stage root is never included.
    public private(set) var roots: Set<PrimPath>

    public init(roots: Set<PrimPath> = []) {
        self.roots = IsolationState.normalize(roots)
    }

    /// `true` when isolate mode is engaged.
    public var isActive: Bool { !roots.isEmpty }

    /// Whether `path` should render under the current isolation.
    ///
    /// With no isolation, everything renders. Under isolation, a prim renders iff
    /// it shares a lineage with some isolated root — i.e. the root is an
    /// ancestor-or-self of the prim (the isolated subtree itself) **or** the prim
    /// is an ancestor of the root (the parents needed to place it in the world).
    /// Siblings and unrelated branches are hidden.
    public func isVisible(_ path: PrimPath) -> Bool {
        guard isActive else { return true }
        return roots.contains { root in
            root == path || root.isAncestor(of: path) || path.isAncestor(of: root)
        }
    }

    /// Returns a new state isolating `paths` (replacing any current isolation).
    /// The stage root and invalid/empty selections clear isolation instead.
    public func isolating(_ paths: some Sequence<PrimPath>) -> IsolationState {
        IsolationState(roots: Set(paths))
    }

    /// Returns a state isolating `paths` added to the current roots.
    public func addingIsolation(_ paths: some Sequence<PrimPath>) -> IsolationState {
        IsolationState(roots: roots.union(paths))
    }

    /// Exit isolate mode.
    public func cleared() -> IsolationState { IsolationState() }

    /// Every prim on `stage` that isolation hides (for the viewport to dim/skip).
    /// Empty when isolation is inactive.
    public func hiddenPaths(in stage: any USDStageProtocol) -> Set<PrimPath> {
        guard isActive else { return [] }
        return Set(stage.allPrims().map(\.path).filter { !isVisible($0) })
    }

    // MARK: Normalization

    /// Drops the root path and any path that is a descendant of another in the
    /// set (a redundant sub-isolation), so `roots` is a minimal cover.
    private static func normalize(_ paths: Set<PrimPath>) -> Set<PrimPath> {
        let candidates = paths.filter { !$0.isRoot }
        return candidates.filter { path in
            !candidates.contains { other in other != path && other.isAncestor(of: path) }
        }
    }
}
