import USDCore

/// The three distinct "make this part go away" semantics that users constantly
/// confuse (specs/editor-ui.md: "this distinction is a top user-confusion risk,
/// so the UI over-communicates it"). Modelling them as one vocabulary lets the
/// outliner, inspector, and context menus present all three side-by-side with
/// consistent, discoverable copy — and lets us unit-test that copy.
///
/// | Kind      | Authoring       | Ships in file? | Undoable | Runtime toggle |
/// |-----------|-----------------|----------------|----------|----------------|
/// | `.hide`   | `visibility`    | yes            | yes      | yes (RealityKit)|
/// | `.disable`| `active = false`| no (pruned)    | yes      | no             |
/// | `.delete` | remove subtree  | no (gone)      | yes      | no             |
public enum PartEditKind: String, CaseIterable, Sendable {
    case hide
    case disable
    case delete

    /// SF Symbol name for the control.
    public var systemImage: String {
        switch self {
        case .hide: return "eye.slash"
        case .disable: return "moon.zzz"
        case .delete: return "trash"
        }
    }

    /// SF Symbol shown when the state is already engaged (Hide→Show, Disable→Enable).
    public var engagedSystemImage: String {
        switch self {
        case .hide: return "eye"
        case .disable: return "moon"
        case .delete: return "trash"
        }
    }

    /// `true` for the one irreversible-in-place action. Delete removes the prim
    /// from the tree (undoable via the command stack, but not a toggle).
    public var isDestructive: Bool { self == .delete }

    /// The one-line "what actually happens", written to defuse the confusion.
    public var help: String {
        switch self {
        case .hide:
            return "Hidden from view but kept in the exported file — toggleable at runtime in RealityKit/Quick Look."
        case .disable:
            return "Deactivated: removed from the composed scene and excluded from export, but recoverable here."
        case .delete:
            return "Removed from the scene entirely. Undoable until you save; gone from the file once saved."
        }
    }
}

/// A single, ready-to-render control describing a part-edit action in its
/// current context (whether it's already engaged, and the label to show).
public struct PartEditControl: Hashable, Sendable, Identifiable {
    public var kind: PartEditKind
    public var title: String
    public var help: String
    public var systemImage: String
    public var isDestructive: Bool
    /// `true` when the prim is already hidden / already disabled. Always `false`
    /// for `.delete` (there is no "already deleted" state for a live prim).
    public var isEngaged: Bool

    public var id: PartEditKind { kind }
}

extension PartEditKind {

    /// The context-aware title (e.g. "Hide" vs. "Show") for `prim`'s state.
    public func title(for prim: Prim) -> String {
        switch self {
        case .hide: return prim.visibility == .invisible ? "Show" : "Hide"
        case .disable: return prim.isActive ? "Disable" : "Enable"
        case .delete: return "Delete"
        }
    }

    /// Whether this action is currently engaged for `prim`.
    public func isEngaged(for prim: Prim) -> Bool {
        switch self {
        case .hide: return prim.visibility == .invisible
        case .disable: return !prim.isActive
        case .delete: return false
        }
    }

    /// Builds the presentable control for `prim`.
    public func control(for prim: Prim) -> PartEditControl {
        let engaged = isEngaged(for: prim)
        return PartEditControl(
            kind: self,
            title: title(for: prim),
            help: help,
            systemImage: engaged ? engagedSystemImage : systemImage,
            isDestructive: isDestructive,
            isEngaged: engaged)
    }

    /// The full trio of controls for `prim`, in Hide · Disable · Delete order —
    /// the canonical presentation the UI renders together.
    public static func controls(for prim: Prim) -> [PartEditControl] {
        allCases.map { $0.control(for: prim) }
    }
}

/// Builds the undoable `EditCommand` that toggles/performs a part-edit action.
public enum PartEditCommandFactory {

    /// Returns the command that applies `kind` to the prim at `path`, or `nil`
    /// when the prim isn't on the stage (or delete can't locate its slot).
    ///
    /// Hide and Disable are toggles: they flip against the prim's current state.
    /// Delete resolves the prim's parent + sibling index so the removal undoes
    /// cleanly.
    public static func command(_ kind: PartEditKind,
                               for path: PrimPath,
                               in stage: any USDStageProtocol) -> (any EditCommand)? {
        guard let prim = stage.prim(at: path) else { return nil }
        switch kind {
        case .hide:
            let target: Visibility = prim.visibility == .invisible ? .inherited : .invisible
            return SetVisibilityCommand(path: path, newVisibility: target, oldVisibility: prim.visibility)
        case .disable:
            return SetActiveCommand(path: path, newValue: !prim.isActive, oldValue: prim.isActive)
        case .delete:
            guard let index = StructureSupport.index(of: path, in: stage) else { return nil }
            return RemovePrimCommand(prim: prim, parent: StructureSupport.parent(of: path), index: index)
        }
    }
}
