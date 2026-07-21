#if canImport(RealityKit)
import Testing
import Foundation
import RealityKit
import simd
@testable import ViewportKit

/// `SceneGraphApplier` carries diff operations onto a live entity tree. Driven
/// here against a bare `Entity` root — no `ARView`, no window — which is why
/// this logic lives outside the coordinator.
@Suite("SceneGraphApplier")
@MainActor
struct SceneGraphApplierTests {

    private func mesh() -> ViewportMeshData {
        ViewportMeshData(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
            faceLoops: [[0, 1, 2]])
    }

    private func translation(_ x: Float) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    private func node(_ path: String, transform: float4x4 = matrix_identity_float4x4,
                      mesh: ViewportMeshData? = nil, isEnabled: Bool = true) -> ViewportPrimNode {
        ViewportPrimNode(path: path, transform: transform, mesh: mesh, isEnabled: isEnabled)
    }

    // MARK: Insertion — the library-add bug

    @Test("A newly inserted mesh prim becomes a rendered child of the root")
    func insertCreatesModelEntity() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/Cube", mesh: mesh())]))

        #expect(root.children.count == 1)
        #expect(applier.synthesized["/Cube"] is ModelEntity)
        #expect(applier.synthesized["/Cube"]?.name == "Cube")
    }

    @Test("A geometry-less grouping prim becomes a plain, non-rendering entity")
    func insertGroupingPrim() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/Group")]))

        let entity = applier.synthesized["/Group"]
        #expect(entity != nil)
        #expect(entity is ModelEntity == false)
    }

    @Test("A child prim parents under its own prim's entity, not the root")
    func insertNestsUnderParent() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/Cube"), node("/Cube/Geo", mesh: mesh())]))

        #expect(root.children.count == 1)
        #expect(applier.synthesized["/Cube/Geo"]?.parent === applier.synthesized["/Cube"])
    }

    @Test("A positions-only edit rebuilds a synthesized entity in place, keeping children")
    func updateVerticesRebuildsSynthesizedEntityPreservingSubtree() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/Cube", mesh: mesh()), node("/Cube/Geo")]))
        let child = applier.synthesized["/Cube/Geo"]
        let originalCube = applier.synthesized["/Cube"]

        // Move one vertex → diff emits .updateVertices → applier rebuilds /Cube.
        var moved = mesh()
        moved.positions[0] = SIMD3(-3, -3, -3)
        applier.apply(ViewportScene([node("/Cube", mesh: moved), node("/Cube/Geo")]))

        let rebuilt = applier.synthesized["/Cube"]
        #expect(rebuilt is ModelEntity)
        #expect(rebuilt !== originalCube)                 // rebuilt in place
        #expect(applier.synthesized["/Cube/Geo"] === child) // subtree preserved
        #expect(rebuilt?.children.first === child)
    }

    @Test("A child whose parent prim isn't drawn falls back to the root")
    func orphanFallsBackToRoot() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/Missing/Geo", mesh: mesh())]))
        #expect(applier.synthesized["/Missing/Geo"]?.parent === root)
    }

    @Test("Insert honours the node's transform and enablement")
    func insertAppliesTransformAndEnablement() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", transform: translation(4),
                                          mesh: mesh(), isEnabled: false)]))

        let entity = applier.synthesized["/A"]
        #expect(entity?.transform.matrix.columns.3.x == 4)
        #expect(entity?.isEnabled == false)
    }

    @Test("Geometry with no drawable triangles degrades to a group entity")
    func degenerateGeometryBecomesGroup() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        let empty = ViewportMeshData(positions: [], faceLoops: [])
        applier.apply(ViewportScene([node("/A", mesh: empty)]))

        #expect(applier.synthesized["/A"] != nil)
        #expect(applier.synthesized["/A"] is ModelEntity == false)
    }

    // MARK: Loader-backed prims are left alone

    @Test("A prim the loader already drew is never synthesized")
    func loaderBackedPrimIsSkipped() {
        let root = Entity()
        let loaded = Entity()
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/FromFile" ? loaded : nil })
        applier.apply(ViewportScene([node("/FromFile", mesh: mesh())]))

        #expect(applier.synthesized["/FromFile"] == nil)
        #expect(root.children.isEmpty)
    }

    @Test("A synthesized child parents under a loader-backed parent entity")
    func synthesizedChildOfLoadedParent() {
        let root = Entity()
        let loaded = Entity()
        root.addChild(loaded)
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/Model" ? loaded : nil })
        applier.apply(ViewportScene([node("/Model"), node("/Model/Added", mesh: mesh())]))

        #expect(applier.synthesized["/Model/Added"]?.parent === loaded)
    }

    // MARK: Removal

    @Test("A removed prim's entity leaves the tree and the index")
    func removeDetachesEntity() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))
        applier.apply(ViewportScene())

        #expect(root.children.isEmpty)
        #expect(applier.synthesized.isEmpty)
    }

    @Test("Removing a subtree forgets every synthesized descendant")
    func removeClearsDescendantsFromIndex() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A"), node("/A/B"), node("/A/B/C", mesh: mesh())]))
        #expect(applier.synthesized.count == 3)

        applier.apply(ViewportScene())
        #expect(applier.synthesized.isEmpty)
        #expect(root.children.isEmpty)
    }

    @Test("Removing one prim leaves an unrelated sibling untouched")
    func removeLeavesSiblings() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh()), node("/B", mesh: mesh())]))
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))

        #expect(applier.synthesized.keys.sorted() == ["/A"])
        #expect(root.children.count == 1)
    }

    // MARK: Updates

    @Test("A transform update moves the entity without replacing it")
    func transformUpdateIsInPlace() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))
        let original = applier.synthesized["/A"]

        applier.apply(ViewportScene([node("/A", transform: translation(7), mesh: mesh())]))
        #expect(applier.synthesized["/A"] === original)
        #expect(applier.synthesized["/A"]?.transform.matrix.columns.3.x == 7)
    }

    @Test("An enablement update toggles the entity in place")
    func enablementUpdateIsInPlace() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))
        applier.apply(ViewportScene([node("/A", mesh: mesh(), isEnabled: false)]))

        #expect(applier.synthesized["/A"]?.isEnabled == false)
    }

    @Test("A mesh update swaps geometry while preserving transform and children")
    func meshUpdatePreservesTransformAndChildren() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", transform: translation(2), mesh: mesh()),
                                     node("/A/Child", mesh: mesh())]))
        let child = applier.synthesized["/A/Child"]

        let bigger = ViewportMeshData(
            positions: [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0)], faceLoops: [[0, 1, 2]])
        applier.apply(ViewportScene([node("/A", transform: translation(2), mesh: bigger),
                                     node("/A/Child", mesh: mesh())]))

        let updated = applier.synthesized["/A"]
        #expect(updated?.transform.matrix.columns.3.x == 2)
        #expect(updated?.name == "A")
        #expect(child?.parent === updated)
        #expect(root.children.count == 1)
    }

    @Test("A mesh update on a disabled prim keeps it disabled")
    func meshUpdatePreservesDisabledState() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh(), isEnabled: false)]))

        let bigger = ViewportMeshData(
            positions: [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0)], faceLoops: [[0, 1, 2]])
        applier.apply(ViewportScene([node("/A", mesh: bigger, isEnabled: false)]))
        #expect(applier.synthesized["/A"]?.isEnabled == false)
    }

    @Test("A mesh update targeting a loader-backed prim is ignored")
    func meshUpdateOnLoaderBackedPrimIsIgnored() {
        let root = Entity()
        let loaded = Entity()
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/F" ? loaded : nil })
        applier.apply(ViewportScene([node("/F", mesh: mesh())]))
        applier.apply(ViewportScene([node("/F", mesh: ViewportMeshData(positions: [], faceLoops: []))]))

        #expect(applier.synthesized.isEmpty)
        #expect(root.children.isEmpty)
    }

    // MARK: Seeding and reset

    @Test("Seeding adopts the scene without synthesizing loader-backed prims")
    func seedSkipsLoaderBackedPrims() {
        let root = Entity()
        let loaded = Entity()
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/FromFile" ? loaded : nil })
        applier.seed(with: ViewportScene([node("/FromFile", mesh: mesh())]))

        #expect(applier.synthesized.isEmpty)
        #expect(applier.appliedScene["/FromFile"] != nil)
    }

    @Test("Seeding synthesizes prims the file did not contain")
    func seedSynthesizesNonFilePrims() {
        let root = Entity()
        let loaded = Entity()
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/FromFile" ? loaded : nil })
        applier.seed(with: ViewportScene([node("/FromFile"), node("/AddedWhileLoading", mesh: mesh())]))

        #expect(applier.synthesized.keys.sorted() == ["/AddedWhileLoading"])
    }

    @Test("Seeding twice discards the previous synthesized entities")
    func seedResetsPriorSynthesis() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.seed(with: ViewportScene([node("/Old", mesh: mesh())]))
        applier.seed(with: ViewportScene([node("/New", mesh: mesh())]))

        #expect(applier.synthesized.keys.sorted() == ["/New"])
    }

    @Test("A seeded scene is the baseline the next diff runs against")
    func seedEstablishesDiffBaseline() {
        let root = Entity()
        let loaded = Entity()
        let applier = SceneGraphApplier(root: root, findLoaded: { $0 == "/FromFile" ? loaded : nil })
        applier.seed(with: ViewportScene([node("/FromFile", mesh: mesh())]))

        // The file prim is already drawn; only the new prim should appear.
        applier.apply(ViewportScene([node("/FromFile", mesh: mesh()), node("/Cube", mesh: mesh())]))
        #expect(applier.synthesized.keys.sorted() == ["/Cube"])
    }

    @Test("Reset detaches every synthesized entity and clears the scene")
    func resetClearsEverything() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))
        applier.reset()

        #expect(root.children.isEmpty)
        #expect(applier.synthesized.isEmpty)
        #expect(applier.appliedScene.isEmpty)
    }

    // MARK: Idempotence

    @Test("Re-applying an identical scene changes nothing")
    func identicalSceneIsANoOp() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        let scene = ViewportScene([node("/A", mesh: mesh())])
        applier.apply(scene)
        let entity = applier.synthesized["/A"]
        applier.apply(scene)

        #expect(applier.synthesized["/A"] === entity)
        #expect(root.children.count == 1)
    }

    @Test("Insert, move, then remove leaves the tree as it started")
    func fullLifecycle() {
        let root = Entity()
        let applier = SceneGraphApplier(root: root)
        applier.apply(ViewportScene([node("/A", mesh: mesh())]))
        applier.apply(ViewportScene([node("/A", transform: translation(1), mesh: mesh())]))
        applier.apply(ViewportScene())

        #expect(root.children.isEmpty)
        #expect(applier.synthesized.isEmpty)
    }

    // MARK: Naming

    @Test("Entity names come from the last path segment")
    func nameOfPath() {
        #expect(SceneGraphApplier.name(of: "/Cube") == "Cube")
        #expect(SceneGraphApplier.name(of: "/Rig/Arm/Hand") == "Hand")
        #expect(SceneGraphApplier.name(of: "Bare") == "Bare")
    }
}
#endif
