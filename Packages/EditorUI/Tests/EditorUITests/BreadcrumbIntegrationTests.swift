import Testing
import USDCore
import EditingKit
import DiagnosticsKit
@testable import EditorUI

/// The session-log integration contract (specs/diagnostics-logging.md): every
/// command commit, undo/redo, and palette dispatch leaves a breadcrumb.
@MainActor
@Suite("Breadcrumb integration")
struct BreadcrumbIntegrationTests {

    private func loggedDocument() -> (EditorDocument, InMemoryBreadcrumbSink) {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
        let sink = InMemoryBreadcrumbSink()
        doc.breadcrumbs = BreadcrumbLogger(sink: sink, flushInterval: nil)
        return (doc, sink)
    }

    @Test("run, undo, and redo emit edit.command crumbs with labels")
    func commandCrumbs() {
        let (doc, sink) = loggedDocument()
        doc.setActive(PrimPath("/Root")!, false)
        doc.undo()
        doc.redo()
        doc.breadcrumbs?.flush()

        let crumbs = sink.crumbs
        #expect(crumbs.allSatisfy { $0.category == .command })
        #expect(crumbs.map(\.message) == ["run", "undo", "redo"])
        #expect(crumbs[0].metadata["label"]?.isEmpty == false)
    }

    @Test("a failed command emits an .error crumb (and flushes immediately)")
    func failedCommandCrumb() {
        let (doc, sink) = loggedDocument()
        // Renaming a nonexistent prim fails inside the stack.
        doc.run(RenamePrimCommand(path: PrimPath("/Missing")!, newName: "X"))
        let crumb = sink.crumbs.last
        #expect(crumb?.level == .error)
        #expect(crumb?.message == "command failed")
        #expect(crumb?.metadata["error"]?.isEmpty == false)
    }

    @Test("nil logger keeps the document silent and functional")
    func nilLoggerIsSilent() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
        doc.setActive(PrimPath("/Root")!, false)
        doc.undo()
        doc.redo()
        #expect(doc.breadcrumbs == nil)
        #expect(doc.canUndo)
    }

    @Test("palette dispatch emits a ui.action crumb with id and title")
    func paletteCrumb() {
        let sink = InMemoryBreadcrumbSink()
        var ran = false
        let model = CommandPaletteModel(actions: [
            PaletteAction(item: ActionItem(id: "save", title: "Save", category: "File")) { ran = true }
        ])
        model.breadcrumbs = BreadcrumbLogger(sink: sink, flushInterval: nil)
        #expect(model.runSelected())
        model.breadcrumbs?.flush()
        #expect(ran)
        #expect(sink.crumbs.last?.category == .action)
        #expect(sink.crumbs.last?.metadata["id"] == "save")
        #expect(sink.crumbs.last?.metadata["title"] == "Save")
    }
}
