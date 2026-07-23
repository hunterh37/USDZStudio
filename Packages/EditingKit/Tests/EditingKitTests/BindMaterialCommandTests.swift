import Testing
import Foundation
import USDCore
@testable import EditingKit

/// Coverage for `BindMaterialCommand`: binding an existing material to another
/// prim so one material is shared across many targets (issue #140/#141) rather
/// than minting a duplicate per target. Exercises the root-prim and nested
/// branches, exact undo reversal, prior-binding replacement, and every `nil`
/// build-failure guard.
@Suite("BindMaterialCommand")
struct BindMaterialCommandTests {

    private func stage(_ roots: [Prim]) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: roots))
    }

    private let materialPath = PrimPath("/Looks/Mat")!

    /// A `/Looks` scope holding one Material, plus the given target roots.
    private func scene(_ targets: [Prim]) -> [Prim] {
        let material = Prim(path: materialPath, typeName: "Material")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [material])
        return [looks] + targets
    }

    private func box(_ name: String, bindingTo material: String? = nil) -> Prim {
        var rels: [Relationship] = []
        if let material, let mp = PrimPath(material) {
            rels.append(Relationship(name: MaterialBinding.key, targets: [mp]))
        }
        return Prim(path: PrimPath("/\(name)")!, typeName: "Xform", relationships: rels)
    }

    // MARK: - Root-prim target

    @Test func bindsExistingMaterialToRootPrim() throws {
        let s = stage(scene([box("Copy")]))
        let target = PrimPath("/Copy")!
        let cmd = try #require(
            BindMaterialCommand.make(materialPath: materialPath, bindingTo: target, in: s))
        try cmd.execute(on: s)
        // The target now resolves to the shared material — no new material minted.
        #expect(MaterialBinding.materialPath(for: target, in: s) == materialPath)
        #expect(s.rootPrims.filter { $0.typeName == "Scope" }.count == 1)
        #expect(cmd.materialPath == materialPath)
        #expect(cmd.targetPath == target)
    }

    @Test func undoRestoresOriginalStateExactly() throws {
        let before = StageSnapshot(rootPrims: scene([box("Copy")]))
        let s = InMemoryStage(before)
        let cmd = try #require(
            BindMaterialCommand.make(materialPath: materialPath, bindingTo: PrimPath("/Copy")!, in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.currentSnapshot == before)
    }

    // MARK: - Nested target + prior-binding replacement

    @Test func bindsNestedTargetAndReplacesPriorBinding() throws {
        // A parent Xform with a child that already binds a different material.
        let other = PrimPath("/Looks/Other")!
        let child = Prim(path: PrimPath("/Group/Child")!, typeName: "Mesh",
                         relationships: [Relationship(name: MaterialBinding.key, targets: [other])])
        let group = Prim(path: PrimPath("/Group")!, typeName: "Xform", children: [child])
        var roots = scene([group])
        // Add the "other" material so the pre-state is well formed.
        roots[0].children.append(Prim(path: other, typeName: "Material"))
        let s = stage(roots)

        let cmd = try #require(
            BindMaterialCommand.make(materialPath: materialPath, bindingTo: child.path, in: s))
        try cmd.execute(on: s)
        // Old binding replaced by the shared one (not appended alongside).
        let bound = try #require(s.prim(at: child.path))
        let rels = bound.relationships.filter { $0.name == MaterialBinding.key }
        #expect(rels.count == 1)
        #expect(rels.first?.targets == [materialPath])
    }

    // MARK: - nil guards

    @Test func nilWhenMaterialMissing() {
        let s = stage([box("Copy")])  // no /Looks material
        #expect(BindMaterialCommand.make(
            materialPath: materialPath, bindingTo: PrimPath("/Copy")!, in: s) == nil)
    }

    @Test func nilWhenMaterialPathIsNotAMaterial() {
        // Point materialPath at a Mesh, not a Material prim.
        let notMaterial = Prim(path: materialPath, typeName: "Mesh")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [notMaterial])
        let s = stage([looks, box("Copy")])
        #expect(BindMaterialCommand.make(
            materialPath: materialPath, bindingTo: PrimPath("/Copy")!, in: s) == nil)
    }

    @Test func nilWhenTargetMissing() {
        let s = stage(scene([]))
        #expect(BindMaterialCommand.make(
            materialPath: materialPath, bindingTo: PrimPath("/Ghost")!, in: s) == nil)
    }

    @Test func nilWhenAlreadyBoundToSameMaterial() {
        // Target already binds exactly this material → no-op, no undo entry.
        let s = stage(scene([box("Copy", bindingTo: materialPath.description)]))
        #expect(BindMaterialCommand.make(
            materialPath: materialPath, bindingTo: PrimPath("/Copy")!, in: s) == nil)
    }
}
