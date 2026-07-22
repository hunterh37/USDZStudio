import Foundation
import DiagnosticsKit

/// Pairs an `ActionItem` descriptor with the closure that performs it. The
/// closure is `@MainActor` (it mutates view state / drives menus), so this type
/// is main-actor isolated; the descriptor half stays a pure value the registry
/// can rank off the main actor.
@MainActor
public struct PaletteAction {
    public let item: ActionItem
    public let run: () -> Void

    public init(item: ActionItem, run: @escaping () -> Void) {
        self.item = item
        self.run = run
    }
}

/// View-state for the command palette: the query, the ranked results, and the
/// highlighted row. It owns an `ActionRegistry` built from the current action
/// set and recomputes results whenever the query or the actions change. Kept
/// separate from the SwiftUI view so navigation/selection logic is unit-tested
/// directly (`CommandPaletteModelTests`).
@MainActor
@Observable
public final class CommandPaletteModel {
    /// The current query. Editing it re-ranks results and re-clamps selection.
    public var query: String = "" {
        didSet { recompute() }
    }

    /// Ranked results for the current query. Read-only to callers.
    public private(set) var results: [ActionItem] = []

    /// Index of the highlighted row within `results`. Always valid when
    /// `results` is non-empty; 0 when empty.
    public var selectedIndex: Int = 0

    private var actions: [PaletteAction]
    private var registry: ActionRegistry

    /// Session breadcrumb trail: every palette-dispatched action is logged
    /// under `ui.action` (specs/diagnostics-logging.md). Property-injected by
    /// the shell; `nil` (tests, previews) is silent.
    @ObservationIgnored public var breadcrumbs: (any BreadcrumbLogging)?

    public init(actions: [PaletteAction] = []) {
        self.actions = actions
        self.registry = ActionRegistry(actions.map(\.item))
        recompute()
    }

    /// Replaces the action set (called each time the palette opens so it reflects
    /// the live document/context) and re-ranks. Leaves the query untouched.
    public func setActions(_ actions: [PaletteAction]) {
        self.actions = actions
        self.registry = ActionRegistry(actions.map(\.item))
        recompute()
    }

    /// Clears the query and selection — used when the palette is dismissed so it
    /// reopens fresh.
    public func reset() {
        selectedIndex = 0
        query = "" // triggers recompute via didSet
    }

    /// The highlighted item, or nil when there are no results.
    public var selectedItem: ActionItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Moves the highlight down one row, stopping at the last result.
    public func moveDown() {
        guard !results.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, results.count - 1)
    }

    /// Moves the highlight up one row, stopping at the first result.
    public func moveUp() {
        guard !results.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    /// Runs the highlighted action when it is enabled. Returns whether anything
    /// ran (false for an empty result set or a disabled selection).
    @discardableResult
    public func runSelected() -> Bool {
        guard let item = selectedItem, item.isEnabled,
              let action = actions.first(where: { $0.item.id == item.id })
        else { return false }
        breadcrumbs?.log(.action, level: .info, "palette",
                         metadata: ["id": item.id, "title": item.title])
        action.run()
        return true
    }

    private func recompute() {
        results = registry.search(query)
        clampSelection()
    }

    private func clampSelection() {
        guard !results.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(0, selectedIndex), results.count - 1)
    }
}
