import Testing
import Foundation
import USDCore
@testable import EditingKit

/// Coverage for `BindMaterialCommand`: binding an EXISTING material to a prim so
/// repetition copies share one material instead of duplicating it (#140/#141).
@Suite("BindMaterialCommand")
struct BindMaterialCommandTests {

    private func stage(_ roots: [Prim]) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: roots))
    }

    private let materialPath = PrimPath("/Looks/Material")!
    private let targetPath = PrimPath("/Copy")!

    /// A stage with one material under /Looks and a bindable target prim.
    private func scene(targetBinding: String? = nil) -> InMemoryStage {
        let material = Prim(path: materialPath, typeName: "Material")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [material])
        var rels: [Relationship] = []
        if let targetBinding, let mp = PrimPath(targetBinding) {
            rels.append(Relationship(name: MaterialBinding.key, targets: [mp]))
        }
        let target = Prim(path: targetPath, typeName: "Mesh", relationships: rels)
        return stage([looks, target])
    }

    @Test func bindsExistingMaterialToTarget() throws {
        let s = scene()
        let cmd = try #require(BindMaterialCommand.make(binding: targetPath, to: materialPath, in: s))
        #expect(cmd.materialPath == materialPath)
        try cmd.execute(on: s)
        #expect(MaterialBinding.materialPath(for: targetPath, in: s) == materialPath)
    }

    @Test func undoRestoresExactly() throws {
        let before = StageSnapshot(rootPrims: scene().rootPrims)
        let s = InMemoryStage(before)
        let cmd = try #require(BindMaterialCommand.make(binding: targetPath, to: materialPath, in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.currentSnapshot == before)
    }

    @Test func replacesAPriorBinding() throws {
        let s = scene(targetBinding: "/Looks/Other")
        // Add the "Other" material so the prior binding is real.
        let other = Prim(path: PrimPath("/Looks/Other")!, typeName: "Material")
        try s.apply(.insertPrim(parent: PrimPath("/Looks")!, index: 1, prim: other))
        let cmd = try #require(BindMaterialCommand.make(binding: targetPath, to: materialPath, in: s))
        try cmd.execute(on: s)
        #expect(MaterialBinding.materialPath(for: targetPath, in: s) == materialPath)
    }

    @Test func nilWhenMaterialMissingOrNotMaterial() throws {
        let s = scene()
        #expect(BindMaterialCommand.make(binding: targetPath, to: PrimPath("/Nope")!, in: s) == nil)
        // Target itself is a Mesh, not a Material.
        #expect(BindMaterialCommand.make(binding: targetPath, to: targetPath, in: s) == nil)
    }

    @Test func nilWhenTargetMissing() throws {
        let s = scene()
        #expect(BindMaterialCommand.make(binding: PrimPath("/Ghost")!, to: materialPath, in: s) == nil)
    }

    @Test func nilWhenAlreadyBoundToSameMaterial() throws {
        let s = scene(targetBinding: "/Looks/Material")
        #expect(BindMaterialCommand.make(binding: targetPath, to: materialPath, in: s) == nil)
    }

    @Test func bindsARootPrimTarget() throws {
        // Exercise the root-index locate() branch.
        let material = Prim(path: materialPath, typeName: "Material")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [material])
        let root = Prim(path: PrimPath("/Building")!, typeName: "Xform")
        let s = stage([looks, root])
        let cmd = try #require(BindMaterialCommand.make(binding: PrimPath("/Building")!, to: materialPath, in: s))
        try cmd.execute(on: s)
        #expect(MaterialBinding.materialPath(for: PrimPath("/Building")!, in: s) == materialPath)
    }
}
