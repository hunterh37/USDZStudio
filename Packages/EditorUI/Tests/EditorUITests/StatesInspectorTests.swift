import Testing
import SwiftUI
import Foundation
import USDCore
import EditingKit
@testable import EditorUI

/// A `mechanism:joint` JSON payload matching `MechanismKit.Joint`'s Codable
/// shape (sorted keys), authored without importing MechanismKit into the UI test
/// target — the same contract `JointCoding.encode` produces.
private func lidHingeJSON(open: Double = 105) -> String {
    """
    {"axis":[1,0,0],"defaultState":"closed","kind":"revolute","maxValue":\(open),\
    "minValue":0,"name":"lidHinge","pivot":[0,0.5,-0.5],\
    "states":[{"name":"closed","value":0},{"name":"open","value":\(open)}],"target":"Lid"}
    """
}

/// A `/Case` assembly whose `Lid` sits under a hinge pivot in the closed pose —
/// exactly what `create_joint` authors, built by hand so the UI test target
/// needs only `EditingKit`'s public `jointAttributeName`.
@MainActor
private func hingedDocument() -> EditorDocument {
    let lid = Prim(path: PrimPath("/Case/Lid_pivot/Lid")!, typeName: "Xform")
    let pivot = Prim(
        path: PrimPath("/Case/Lid_pivot")!, typeName: "Xform",
        attributes: [Attribute(name: jointAttributeName,
                               value: .string(lidHingeJSON()), isUniform: true)],
        children: [lid])
    let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [pivot])
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
}

@MainActor
@Suite struct StatesInspectorTests {

    // MARK: Document — discovery

    @Test func articulationsSurfacesHingeClosed() throws {
        let doc = hingedDocument()
        let joints = doc.articulations
        #expect(joints.count == 1)
        let j = try #require(joints.first)
        #expect(j.pivotPath == PrimPath("/Case/Lid_pivot")!)
        #expect(j.activeState == "closed")
    }

    @Test func stageVariantSetsAreCollectedStageWide() {
        let vs = VariantSet(name: "color", variants: ["red", "blue"], selection: "red")
        let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh", variantSets: [vs])
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [car]))
        let sets = doc.stageVariantSets
        #expect(sets.count == 1)
        #expect(sets.first?.path == PrimPath("/Car/Body")!)
        #expect(sets.first?.set.name == "color")
    }

    // MARK: Document — driving joints

    @Test func setJointStateOpensAndSelectsPivotUndoably() throws {
        let doc = hingedDocument()
        let pivot = PrimPath("/Case/Lid_pivot")!

        doc.setJointState(pivot, state: "open")
        #expect(doc.articulations.first?.activeState == "open")
        #expect(doc.selection.contains(pivot))
        #expect(doc.canUndo)

        doc.undo()
        #expect(doc.articulations.first?.activeState == "closed")
    }

    @Test func setJointStateIgnoresUnknownState() {
        let doc = hingedDocument()
        doc.setJointState(PrimPath("/Case/Lid_pivot")!, state: "ajar")
        #expect(doc.articulations.first?.activeState == "closed")
        #expect(!doc.canUndo)
    }

    @Test func setJointStateIgnoresNonJointPath() {
        let doc = hingedDocument()
        doc.setJointState(PrimPath("/Case")!, state: "open")
        #expect(!doc.canUndo)
    }

    @Test func setJointValueDrivesAnInBetweenPose() throws {
        let doc = hingedDocument()
        doc.setJointValue(PrimPath("/Case/Lid_pivot")!, value: 50)
        let j = try #require(doc.articulations.first)
        #expect(j.activeState == nil)
        #expect(abs(j.currentValue - 50) < 1e-6)
    }

    @Test func setJointValueIgnoresOutOfLimitValue() {
        let doc = hingedDocument()
        doc.setJointValue(PrimPath("/Case/Lid_pivot")!, value: 999)
        #expect(!doc.canUndo)
    }

    // MARK: Views — render every branch

    @Test func statesTabRendersWithMechanismAndRows() {
        let doc = hingedDocument()
        _ = InspectorView(document: doc, initialTab: .states).body
        // Exercise the row + chip bodies directly (ForEach builds them lazily).
        let joint = doc.articulations[0]
        _ = StatesEditor(document: doc).body
        _ = JointStateRow(document: doc, joint: joint).body
        _ = StateChip(title: "open", isActive: false, action: {}).body
        _ = StateChip(title: "closed", isActive: true, action: {}).body
    }

    @Test func statesTabEmptyStateRenders() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/Rock")!, typeName: "Mesh")]))
        _ = StatesEditor(document: doc).body
    }

    @Test func statesTabWithNoDocumentRendersEmpty() {
        _ = InspectorView(document: nil, initialTab: .states).body
    }
}
