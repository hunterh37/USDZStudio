import Testing
import SwiftUI
import Foundation
import USDCore
import EditingKit
@testable import EditorUI

/// Body-exercise coverage for the remaining thin projection views: breadcrumb,
/// command palette, settings, and recolor panels across their populated/empty
/// branches.
@MainActor
@Suite struct MiscViewCoverageTests {

    private func carDoc() -> EditorDocument {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])
        return EditorDocument(snapshot: StageSnapshot(rootPrims: [car]))
    }

    @Test func breadcrumbBarBranches() {
        // Empty selection, no isolation → the guard hides the bar (body still runs).
        let empty = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = BreadcrumbBar(document: empty).body

        // A deep selection populates crumbs and the walk-up button.
        let doc = carDoc()
        doc.selection = Selection([PrimPath("/Car/Wheel")!])
        _ = BreadcrumbBar(document: doc).body
    }

    @Test func commandPaletteViewBody() {
        let model = CommandPaletteModel(actions: [
            PaletteAction(item: ActionItem(id: "save", title: "Save", category: "File")) {},
            PaletteAction(item: ActionItem(id: "undo", title: "Undo", category: "Edit",
                                           isEnabled: false)) {},
        ])
        _ = CommandPaletteView(model: model, onClose: {}).body
        // Filtered + empty-results branches.
        model.query = "save"
        _ = CommandPaletteView(model: model, onClose: {}).body
        model.query = "zzzz-nothing"
        _ = CommandPaletteView(model: model, onClose: {}).body
    }

    @Test func settingsViewBody() {
        let defaults = UserDefaults(suiteName: "settings-view-test")!
        let settings = EditorSettings(defaults: defaults)
        _ = SettingsView(settings: settings).body
    }

    @Test func recolorPanelBranches() {
        _ = RecolorPanel(document: nil, onClose: {}).body

        // Document carrying materials → the populated content branch.
        let paint = Prim(path: PrimPath("/Looks/Paint")!, typeName: "Material", attributes: [
            Attribute(name: "inputs:diffuseColor", value: .vector([0.2, 0.3, 0.4])),
        ])
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [paint])
        let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh",
            relationships: [Relationship(name: "material:binding", targets: [paint.path])])
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [looks, car]))
        _ = RecolorPanel(document: doc, onClose: {}).body
    }
}
