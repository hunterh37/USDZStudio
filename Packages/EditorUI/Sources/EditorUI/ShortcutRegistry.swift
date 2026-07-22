import Foundation
import ViewportKit

/// The single source of truth for every viewport hotkey. All discoverability
/// surfaces read from here — the `?` reference overlay, the transient hint
/// toast, control tooltips, and (once ⌘K lands) the command palette — so a
/// shortcut added once appears everywhere and no key string is hand-written in
/// a view.
///
/// Pure, `Sendable` data: unit-tested for completeness (every `GizmoMode` and
/// `ModalTransformKind` has an entry) and for uniqueness within a group.
public struct ViewportShortcut: Equatable, Sendable, Identifiable {
    /// The key(s), rendered as-is (e.g. "G", "X / Y / Z", "⇧-drag").
    public let keys: String
    /// What the shortcut does.
    public let title: String
    /// SF Symbol name for optional adornment.
    public let symbol: String

    public var id: String { "\(group)-\(keys)-\(title)" }
    /// Set when the shortcut is filed into a group (see `ShortcutRegistry`).
    public fileprivate(set) var group: ShortcutGroup = .transformModal

    public init(keys: String, title: String, symbol: String = "keyboard") {
        self.keys = keys
        self.title = title
        self.symbol = symbol
    }
}

/// The logical grouping the reference overlay lays out by.
public enum ShortcutGroup: String, CaseIterable, Sendable, Identifiable {
    case transformModal = "Transform (modal)"
    case transformGizmo = "Transform (gizmo)"
    case camera = "Camera"
    case selection = "Selection"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// The registry itself — a namespace of pure static data.
public enum ShortcutRegistry {

    /// Every registered shortcut, filed under its group.
    public static let groups: [ShortcutGroup: [ViewportShortcut]] = {
        var out: [ShortcutGroup: [ViewportShortcut]] = [:]
        func file(_ group: ShortcutGroup, _ shortcuts: [ViewportShortcut]) {
            out[group] = shortcuts.map { var s = $0; s.group = group; return s }
        }

        file(.transformModal, [
            ViewportShortcut(keys: "G", title: "Grab / move", symbol: "move.3d"),
            ViewportShortcut(keys: "R", title: "Rotate", symbol: "rotate.3d"),
            ViewportShortcut(keys: "S", title: "Scale", symbol: "arrow.up.left.and.arrow.down.right"),
            ViewportShortcut(keys: "X / Y / Z", title: "Lock to axis (repeat = local)", symbol: "line.diagonal"),
            ViewportShortcut(keys: "⇧ X / Y / Z", title: "Lock to plane", symbol: "square.dashed"),
            ViewportShortcut(keys: "0–9 . -", title: "Type an exact value", symbol: "number"),
            ViewportShortcut(keys: "drag", title: "Grab the selected body", symbol: "hand.point.up.left"),
            ViewportShortcut(keys: "⏎ / click", title: "Confirm", symbol: "return"),
            ViewportShortcut(keys: "⎋", title: "Cancel", symbol: "escape"),
        ])

        file(.transformGizmo, [
            ViewportShortcut(keys: "W", title: "Move gizmo", symbol: "move.3d"),
            ViewportShortcut(keys: "E", title: "Rotate gizmo", symbol: "rotate.3d"),
            ViewportShortcut(keys: "R", title: "Scale gizmo", symbol: "arrow.up.left.and.arrow.down.right"),
        ])

        file(.camera, [
            ViewportShortcut(keys: "drag", title: "Orbit", symbol: "rotate.3d"),
            ViewportShortcut(keys: "⇧-drag / middle-drag", title: "Pan", symbol: "hand.draw"),
            ViewportShortcut(keys: "scroll / pinch", title: "Dolly", symbol: "plus.magnifyingglass"),
            ViewportShortcut(keys: "F", title: "Frame selection", symbol: "viewfinder"),
            ViewportShortcut(keys: "⇥", title: "Toggle edit mode", symbol: "cube.transparent"),
        ])

        file(.selection, [
            ViewportShortcut(keys: "click", title: "Select", symbol: "cursorarrow"),
            ViewportShortcut(keys: "⇧-click", title: "Add / remove from selection", symbol: "cursorarrow.click.2"),
            ViewportShortcut(keys: "⌘I", title: "Isolate selection", symbol: "eye"),
            ViewportShortcut(keys: "⎋", title: "Clear selection / exit isolate", symbol: "escape"),
            ViewportShortcut(keys: "?", title: "Show all shortcuts", symbol: "questionmark.circle"),
        ])

        return out
    }()

    /// Groups in a stable display order (matches `ShortcutGroup.allCases`).
    public static var orderedGroups: [(group: ShortcutGroup, shortcuts: [ViewportShortcut])] {
        ShortcutGroup.allCases.compactMap { g in
            guard let s = groups[g], !s.isEmpty else { return nil }
            return (g, s)
        }
    }

    /// Every registered shortcut, flattened.
    public static var all: [ViewportShortcut] { orderedGroups.flatMap(\.shortcuts) }

    /// The one-line essentials shown in the transient hint toast.
    public static let hintLine = "G move · R rotate · S scale · drag to grab · ? all shortcuts"
}
