import Testing
import SwiftUI
import Foundation
import USDCore
import EditingKit
import ValidationKit
import ScriptingKit
import MeshKit
@testable import EditorUI

/// A richly-populated document: a Car with a bound material carrying authored
/// inputs, variant sets, metadata, and animation metadata, so the inspector and
/// material editor exercise every conditional branch of their bodies.
@MainActor
private func richDocument() -> EditorDocument {
    let paint = Prim(path: PrimPath("/Looks/Paint")!, typeName: "Material", attributes: [
        Attribute(name: "inputs:diffuseColor", value: .vector([0.2, 0.3, 0.4])),
        Attribute(name: "inputs:roughness", value: .double(0.4)),
    ])
    let glass = Prim(path: PrimPath("/Looks/Glass")!, typeName: "Material", attributes: [
        Attribute(name: "inputs:diffuseColor", value: .vector([0.1, 0.1, 0.1])),
    ])
    let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [paint, glass])
    let colorSet = VariantSet(name: "color", variants: ["red", "blue"], selection: "red")
    let body = Prim(
        path: PrimPath("/Car/Body")!, typeName: "Mesh",
        attributes: [Attribute(name: "points", value: .float3Array([0, 0, 0]))],
        relationships: [Relationship(name: "material:binding", targets: [paint.path])],
        metadata: ["kind": "component"],
        variantSets: [colorSet])
    let windows = Prim(
        path: PrimPath("/Car/Windows")!, typeName: "Mesh",
        relationships: [Relationship(name: "material:binding", targets: [glass.path])])
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body, windows])
    var meta = StageMetadata(upAxis: .y, metersPerUnit: 0.01)
    meta.startTimeCode = 1
    meta.endTimeCode = 24
    meta.timeCodesPerSecond = 24
    meta.customLayerData = ["author": "test"]
    let doc = EditorDocument(snapshot: StageSnapshot(metadata: meta, rootPrims: [looks, car]))
    doc.selection = Selection([PrimPath("/Car/Body")!])
    return doc
}

@MainActor
@Suite struct PanelViewCoverageTests {

    // MARK: InspectorView — every tab, populated + empty

    @Test func inspectorAllTabsPopulated() {
        let doc = richDocument()
        for tab in InspectorView.Tab.allCases {
            _ = InspectorView(document: doc, initialTab: tab).body
            #expect(tab.id == tab.rawValue)
        }
    }

    @Test func inspectorAllTabsWithNoDocument() {
        for tab in InspectorView.Tab.allCases {
            _ = InspectorView(document: nil, initialTab: tab).body
        }
    }

    @Test func inspectorMaterialTabNoMaterialState() {
        // Selection on an unpainted prim → the "create & assign" empty state.
        let mesh = Prim(path: PrimPath("/Model/Body")!, typeName: "Mesh")
        let model = Prim(path: PrimPath("/Model")!, typeName: "Xform", children: [mesh])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [model]))
        doc.selection = Selection([PrimPath("/Model/Body")!])
        _ = InspectorView(document: doc, initialTab: .material).body
    }

    // MARK: MaterialEditor — bound material with recolor + all input kinds

    @Test func materialEditorBodyMultiMaterial() throws {
        let doc = richDocument()
        // Model-wide recolor section requires >1 material under the selection.
        doc.selection = Selection([PrimPath("/Car")!])
        let material = try #require(doc.boundMaterial(for: PrimPath("/Car/Body")!)
            ?? doc.materials(under: [PrimPath("/Car")!]).first)
        _ = MaterialEditor(document: doc, material: material,
                           selected: PrimPath("/Car/Body")!).body
    }

    @Test func materialEditorBodySingleMaterialInherited() throws {
        let doc = richDocument()
        doc.selection = Selection([PrimPath("/Car/Body")!])
        let material = try #require(doc.boundMaterial(for: PrimPath("/Car/Body")!))
        _ = MaterialEditor(document: doc, material: material,
                           selected: PrimPath("/Car/Body")!).body
    }

    // MARK: MeshEditOverlay — object mode (hidden) + edit mode across tools

    @Test func meshEditOverlayHiddenInObjectMode() {
        let doc = richDocument()
        _ = MeshEditOverlay(document: doc).body
    }

    @Test func meshEditOverlayCoversEveryTool() {
        let mesh = Prim(
            path: PrimPath("/Root/Panel")!, typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])),
                Attribute(name: "faceVertexCounts", value: .intArray([4])),
                Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
            ])
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
        doc.enterMeshEditMode(at: PrimPath("/Root/Panel")!)

        // No tool armed → the "No tool" indicator branch + face picker.
        _ = MeshEditOverlay(document: doc).body

        for tool in MeshTool.allCases {
            doc.meshEdit?.tool = tool
            _ = MeshEditOverlay(document: doc).body
        }

        // Diagnostic + hover-preview branches.
        doc.meshEdit?.tool = .extrude
        doc.meshEdit?.lastDiagnostic = "boom"
        doc.meshEdit?.hoverPreviewEnabled = true
        doc.meshEdit?.hoveredFaceIndex = 0
        _ = MeshEditOverlay(document: doc).body

        // Select-all face branch.
        doc.selectMeshFace(index: nil)
        _ = MeshEditOverlay(document: doc).body
    }

    // MARK: ValidationDrawer — nil stage and a real stage

    @Test func validationDrawerNilStage() {
        _ = ValidationDrawer(stage: nil, onSelectPrim: { _ in },
                             quickFix: { _ in nil }, onApplyFix: { _ in }, onClose: {}).body
    }

    @Test func validationDrawerRealStage() {
        let doc = richDocument()
        let stage = doc.snapshot
        _ = ValidationDrawer(
            stage: stage,
            onSelectPrim: { _ in },
            quickFix: { QuickFixRegistry.quickFix(for: $0, in: stage) },
            onApplyFix: { _ in },
            onClose: {}).body
    }

    // MARK: LibraryPanel — nil and real document; performInsert paths

    @Test func libraryPanelBodies() {
        _ = LibraryPanel(onClose: {}, document: nil).body
        _ = LibraryPanel(onClose: {}, document: richDocument()).body
    }

    @Test func libraryPerformInsertPaths() {
        let entry = ShapeLibrary.entry(id: "prim.cube")!
        let doc = richDocument()
        let inserted = LibraryPanel.performInsert(entry, document: doc,
                                                  createDocument: { nil }, dismiss: {})
        #expect(inserted.contains(entry.name))

        // No document but createDocument supplies one.
        let scratch = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let created = LibraryPanel.performInsert(entry, document: nil,
                                                 createDocument: { scratch }, dismiss: {})
        #expect(created.contains(entry.name))

        // No document and none can be created → failure line.
        let failed = LibraryPanel.performInsert(entry, document: nil,
                                                createDocument: { nil }, dismiss: {})
        #expect(failed.contains("Couldn"))
    }

    // MARK: ExportView — button, panel across verdicts, toast

    @Test func exportButtonStates() {
        _ = ExportButton(onQuickExport: {}, onOpenPanel: {}).body
        _ = ExportButton(onQuickExport: {}, onOpenPanel: {}, isEnabled: false, isBusy: true).body
    }

    @Test func exportPanelBodies() {
        // No evaluator → compliance section hidden.
        _ = ExportPanel(sourceURL: URL(fileURLWithPath: "/tmp/a.usdz"),
                        evaluate: nil, onExport: { _ in }, onClose: {}).body

        // Real evaluator over a stage with a scale problem → blocked/advisory.
        let doc = richDocument()
        let stage = doc.snapshot
        _ = ExportPanel(sourceURL: URL(fileURLWithPath: "/tmp/a.usdz"),
                        evaluate: { ExportGate.evaluate(stage: stage, profileID: $0) },
                        onExport: { _ in }, onClose: {}).body

        // Clean stage → clean verdict branch.
        let clean = EditorDocument(snapshot: StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/Root")!, typeName: "Xform")]))
        _ = ExportPanel(sourceURL: nil,
                        evaluate: { ExportGate.evaluate(stage: clean.snapshot, profileID: $0) },
                        onExport: { _ in }, onClose: {}).body
    }

    @Test func exportToastBodies() {
        _ = ExportToast(fileName: "out.usdz", errorMessage: nil,
                        onReveal: {}, onDismiss: {}).body
        _ = ExportToast(fileName: "out.usdz", errorMessage: "disk full",
                        onReveal: {}, onDismiss: {}).body
    }

    // MARK: ScriptsPanel

    @Test func scriptsPanelBody() {
        _ = ScriptsPanel(onClose: {}, inputURL: URL(fileURLWithPath: "/tmp/in.usda")).body
    }

    // MARK: TutorialOverlay — step across the whole tour

    @Test func tutorialOverlayAcrossSteps() throws {
        let engine = try TutorialEngine()
        _ = TutorialOverlay(engine: engine).body
        // Walk the steps (without awaiting long animations) to hit the last-step
        // and progress-dot branches; stepIndex advances synchronously.
        for _ in engine.steps.indices {
            _ = TutorialOverlay(engine: engine).body
            if !engine.isLastStep && !engine.isAnimating { engine.next() }
        }
        _ = TutorialOverlay(engine: engine).body
        engine.skip()
    }
}
