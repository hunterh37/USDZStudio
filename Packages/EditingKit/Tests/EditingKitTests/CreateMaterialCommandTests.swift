import Testing
import Foundation
import USDCore
@testable import EditingKit

/// End-to-end coverage for `CreateMaterialCommand`: the "this model has no
/// material yet — author one and bind it" path. Exercises both the fresh-scope
/// and existing-`/Looks` branches, exact undo reversal, name uniquing, prior
/// binding replacement, inherited resolution, and the `nil` build failure.
@Suite("CreateMaterialCommand")
struct CreateMaterialCommandTests {

    private func stage(_ roots: [Prim]) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: roots))
    }

    private let carPath = PrimPath("/Car")!

    private func car(bindingTo material: String? = nil) -> Prim {
        var rels: [Relationship] = []
        if let material, let mp = PrimPath(material) {
            rels.append(Relationship(name: MaterialBinding.key, targets: [mp]))
        }
        return Prim(path: carPath, typeName: "Xform", relationships: rels,
                    children: [Prim(path: carPath.appending("Body")!, typeName: "Mesh")])
    }

    // MARK: fresh-scope branch

    @Test func createsLooksScopeMaterialAndBinding() throws {
        let s = stage([car()])
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: carPath, in: s))
        try cmd.execute(on: s)

        // A /Looks scope now exists holding the new material.
        let looks = try #require(s.rootPrims.first { $0.name == "Looks" })
        #expect(looks.typeName == "Scope")
        #expect(cmd.materialPath == PrimPath("/Looks/Material"))
        let material = try #require(s.prim(at: cmd.materialPath))
        #expect(material.typeName == "Material")

        // The shader child carries the preview-surface id + a diffuseColor.
        let surface = try #require(s.prim(at: cmd.surfacePath))
        #expect(surface.attribute(named: "info:id")?.value == .token(MaterialBinding.previewSurfaceID))
        #expect(surface.attribute(named: "inputs:diffuseColor")?.value == .vector([0.18, 0.18, 0.18]))

        // The binding resolves from the model root and from a leaf mesh (inherited).
        #expect(MaterialBinding.materialPath(for: carPath, in: s) == cmd.materialPath)
        #expect(MaterialBinding.materialPath(for: carPath.appending("Body")!, in: s) == cmd.materialPath)
    }

    @Test func undoRestoresOriginalStateExactly() throws {
        let before = StageSnapshot(rootPrims: [car()])
        let s = InMemoryStage(before)
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: carPath, in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.currentSnapshot == before)
    }

    @Test func honoursCustomBaseColor() throws {
        let s = stage([car()])
        let cmd = try #require(
            CreateMaterialCommand.make(bindingTo: carPath, baseColor: [1, 0, 0], in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: cmd.surfacePath)?.attribute(named: "inputs:diffuseColor")?.value
                == .vector([1, 0, 0]))
    }

    // MARK: existing-scope branch

    @Test func reusesExistingLooksScopeAndUniquesName() throws {
        let existing = Prim(
            path: PrimPath("/Looks")!, typeName: "Scope",
            children: [Prim(path: PrimPath("/Looks/Material")!, typeName: "Material")])
        let s = stage([existing, car()])
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: carPath, in: s))
        try cmd.execute(on: s)

        // No second /Looks scope; the new material dodges the taken name.
        #expect(s.rootPrims.filter { $0.name == "Looks" }.count == 1)
        #expect(cmd.materialPath == PrimPath("/Looks/Material_1"))
        #expect(s.prim(at: cmd.materialPath) != nil)
    }

    @Test func undoWithExistingScopeRemovesOnlyNewMaterial() throws {
        let existing = Prim(
            path: PrimPath("/Looks")!, typeName: "Scope",
            children: [Prim(path: PrimPath("/Looks/Material")!, typeName: "Material")])
        let before = StageSnapshot(rootPrims: [existing, car()])
        let s = InMemoryStage(before)
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: carPath, in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.currentSnapshot == before)
        // The pre-existing material survived the round-trip.
        #expect(s.prim(at: PrimPath("/Looks/Material")!) != nil)
    }

    // MARK: binding replacement + nested target

    @Test func replacesPriorBindingRatherThanStacking() throws {
        let s = stage([car(bindingTo: "/Looks/Old")])
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: carPath, in: s))
        try cmd.execute(on: s)
        let bound = try #require(s.prim(at: carPath))
        let bindings = bound.relationships.filter { $0.name == MaterialBinding.key }
        #expect(bindings.count == 1)
        #expect(bindings.first?.targets == [cmd.materialPath])
    }

    @Test func bindsNestedTargetPrim() throws {
        let root = Prim(path: PrimPath("/World")!, typeName: "Xform",
                        children: [Prim(path: PrimPath("/World/Prop")!, typeName: "Mesh")])
        let s = stage([root])
        let target = PrimPath("/World/Prop")!
        let cmd = try #require(CreateMaterialCommand.make(bindingTo: target, in: s))
        try cmd.execute(on: s)
        let bound = try #require(s.prim(at: target))
        #expect(bound.relationships.contains { $0.name == MaterialBinding.key })
        #expect(cmd.label == "Create Material on Prop")
    }

    // MARK: failure path

    @Test func returnsNilWhenTargetMissing() {
        let s = stage([car()])
        #expect(CreateMaterialCommand.make(bindingTo: PrimPath("/Ghost")!, in: s) == nil)
    }
}
