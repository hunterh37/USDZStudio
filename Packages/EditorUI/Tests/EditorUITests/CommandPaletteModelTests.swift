import Testing
@testable import EditorUI

@MainActor
@Suite("CommandPaletteModel")
struct CommandPaletteModelTests {

    private func actions(_ log: Log) -> [PaletteAction] {
        [
            PaletteAction(item: ActionItem(id: "save", title: "Save", category: "File")) { log.record("save") },
            PaletteAction(item: ActionItem(id: "export", title: "Export", category: "File")) { log.record("export") },
            PaletteAction(item: ActionItem(id: "undo", title: "Undo", category: "Edit", isEnabled: false)) { log.record("undo") },
        ]
    }

    /// Reference box so a `@MainActor` closure can record invocations.
    final class Log {
        private(set) var events: [String] = []
        func record(_ e: String) { events.append(e) }
    }

    @Test("initial state shows all actions with the first highlighted")
    func initialState() {
        let model = CommandPaletteModel(actions: actions(Log()))
        #expect(model.results.count == 3)
        #expect(model.selectedIndex == 0)
        // Empty-query order is enabled-first, then category, then title: "Export"
        // precedes "Save" (both File); disabled "Undo" sorts last.
        #expect(model.selectedItem?.id == "export")
        #expect(model.results.last?.id == "undo")
    }

    @Test("query filters and re-clamps the selection")
    func queryFilters() {
        let model = CommandPaletteModel(actions: actions(Log()))
        model.selectedIndex = 2
        model.query = "export"
        #expect(model.results.map(\.id) == ["export"])
        #expect(model.selectedIndex == 0)          // clamped back into range
        #expect(model.selectedItem?.id == "export")
    }

    @Test("arrow navigation is bounded at both ends")
    func navigationBounds() {
        let model = CommandPaletteModel(actions: actions(Log()))
        model.moveUp()                              // already at top
        #expect(model.selectedIndex == 0)
        model.moveDown(); model.moveDown(); model.moveDown()
        #expect(model.selectedIndex == 2)           // last row, no overflow
        model.moveUp()
        #expect(model.selectedIndex == 1)
    }

    @Test("navigation is a no-op with no results")
    func navigationEmpty() {
        let model = CommandPaletteModel(actions: actions(Log()))
        model.query = "zzzzz"
        #expect(model.results.isEmpty)
        model.moveDown(); model.moveUp()
        #expect(model.selectedIndex == 0)
        #expect(model.selectedItem == nil)
        #expect(model.runSelected() == false)
    }

    @Test("runSelected invokes the highlighted action's closure")
    func runSelected() {
        let log = Log()
        let model = CommandPaletteModel(actions: actions(log))
        model.query = "export"
        #expect(model.runSelected() == true)
        #expect(log.events == ["export"])
    }

    @Test("runSelected refuses a disabled action")
    func runDisabled() {
        let log = Log()
        let model = CommandPaletteModel(actions: actions(log))
        model.query = "undo"
        #expect(model.selectedItem?.id == "undo")
        #expect(model.runSelected() == false)
        #expect(log.events.isEmpty)
    }

    @Test("setActions swaps context and re-ranks; reset clears the query")
    func setActionsAndReset() {
        let log = Log()
        let model = CommandPaletteModel()
        #expect(model.results.isEmpty)
        model.setActions(actions(log))
        #expect(model.results.count == 3)
        model.query = "save"
        model.reset()
        #expect(model.query.isEmpty)
        #expect(model.selectedIndex == 0)
        #expect(model.results.count == 3)
    }
}
