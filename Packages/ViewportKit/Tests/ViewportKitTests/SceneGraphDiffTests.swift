import Testing
import Foundation
import simd
@testable import ViewportKit

private func mesh(_ x: Float = 0) -> ViewportMeshData {
    ViewportMeshData(
        positions: [SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0), SIMD3(x + 1, 1, 0)],
        faceLoops: [[0, 1, 2]])
}

/// Same triangle plus a second face and a fourth vertex — a genuine *topology*
/// change relative to `mesh()`, so the diff must fall back to a full re-mesh.
private func meshTopoChanged() -> ViewportMeshData {
    ViewportMeshData(
        positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
        faceLoops: [[0, 1, 2], [0, 2, 3]])
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

@Suite("ViewportPrimNode")
struct ViewportPrimNodeTests {

    @Test("A root prim has no parent")
    func rootHasNoParent() {
        #expect(node("/Cube").parentPath == nil)
    }

    @Test("A nested prim's parent is its path minus the last segment")
    func nestedParent() {
        #expect(node("/Cube/Geo").parentPath == "/Cube")
        #expect(node("/Rig/Arm/Hand").parentPath == "/Rig/Arm")
    }

    @Test("A path with no slash at all has no parent")
    func malformedPathHasNoParent() {
        #expect(node("Cube").parentPath == nil)
        #expect(node("").parentPath == nil)
    }

    @Test("Depth counts path segments")
    func depth() {
        #expect(node("/Cube").depth == 1)
        #expect(node("/Cube/Geo").depth == 2)
        #expect(node("/Rig/Arm/Hand").depth == 3)
    }

    @Test("Defaults are an identity-transformed, enabled, geometry-less group")
    func defaults() {
        let n = ViewportPrimNode(path: "/Group")
        #expect(n.transform == matrix_identity_float4x4)
        #expect(n.mesh == nil)
        #expect(n.isEnabled)
    }
}

@Suite("ViewportScene")
struct ViewportSceneTests {

    @Test("An array of nodes keys itself by path")
    func initFromArray() {
        let scene = ViewportScene([node("/A"), node("/A/B")])
        #expect(scene.nodes.count == 2)
        #expect(scene["/A/B"]?.path == "/A/B")
        #expect(scene["/nope"] == nil)
    }

    @Test("Duplicate paths resolve to the last one wins")
    func duplicatePathsLastWins() {
        let scene = ViewportScene([node("/A", mesh: mesh(0)), node("/A", mesh: mesh(5))])
        #expect(scene.nodes.count == 1)
        #expect(scene["/A"]?.mesh == mesh(5))
    }

    @Test("An empty scene reports empty; a populated one does not")
    func emptiness() {
        #expect(ViewportScene().isEmpty)
        #expect(ViewportScene(nodes: ["/A": node("/A")]).isEmpty == false)
    }
}

@Suite("ViewportMeshData.positionChanges")
struct PositionChangesTests {

    @Test("Identical meshes report an empty change set (same topology, no motion)")
    func identicalIsEmpty() {
        #expect(mesh(0).positionChanges(to: mesh(0)) == [:])
    }

    @Test("Different vertex counts report nil — a topology change")
    func differentCountIsNil() {
        #expect(mesh(0).positionChanges(to: meshTopoChanged()) == nil)
    }

    @Test("Different face loops at equal vertex count report nil")
    func differentFaceLoopsIsNil() {
        let a = ViewportMeshData(positions: mesh(0).positions, faceLoops: [[0, 1, 2]])
        let b = ViewportMeshData(positions: mesh(0).positions, faceLoops: [[2, 1, 0]])
        #expect(a.positionChanges(to: b) == nil)
    }

    @Test("Only the moved slots are reported")
    func reportsMovedSlotsOnly() {
        var b = mesh(0)
        b.positions[2] = SIMD3(7, 8, 9)
        #expect(mesh(0).positionChanges(to: b) == [2: SIMD3(7, 8, 9)])
    }
}

@Suite("SceneGraphDiff")
struct SceneGraphDiffTests {

    @Test("Two identical scenes produce no work")
    func noChange() {
        let scene = ViewportScene([node("/A", mesh: mesh()), node("/A/Geo")])
        #expect(SceneGraphDiff.operations(from: scene, to: scene).isEmpty)
    }

    @Test("A prim added to the stage is inserted — the library-insert case")
    func insertion() {
        let before = ViewportScene([node("/Existing")])
        let added = node("/Cube", mesh: mesh())
        let after = ViewportScene([node("/Existing"), added])
        #expect(SceneGraphDiff.operations(from: before, to: after) == [.insert(added)])
    }

    @Test("Inserts arrive parent-before-child regardless of dictionary order")
    func insertsAreParentFirst() {
        let after = ViewportScene([node("/A/B/C"), node("/A"), node("/A/B")])
        let paths = SceneGraphDiff.operations(from: ViewportScene(), to: after).map { op -> String in
            guard case .insert(let n) = op else { return "?" }
            return n.path
        }
        #expect(paths == ["/A", "/A/B", "/A/B/C"])
    }

    @Test("Siblings at equal depth insert in a stable path order")
    func siblingOrderIsStable() {
        let after = ViewportScene([node("/Zebra"), node("/Apple"), node("/Mango")])
        let paths = SceneGraphDiff.operations(from: ViewportScene(), to: after).map { op -> String in
            guard case .insert(let n) = op else { return "?" }
            return n.path
        }
        #expect(paths == ["/Apple", "/Mango", "/Zebra"])
    }

    @Test("A removed prim is removed")
    func removal() {
        let before = ViewportScene([node("/A"), node("/B")])
        let after = ViewportScene([node("/A")])
        #expect(SceneGraphDiff.operations(from: before, to: after) == [.remove(path: "/B")])
    }

    @Test("Removing a subtree emits only its root — children leave with it")
    func removalCollapsesToSubtreeRoot() {
        let before = ViewportScene([node("/A"), node("/A/B"), node("/A/B/C")])
        let after = ViewportScene()
        #expect(SceneGraphDiff.operations(from: before, to: after) == [.remove(path: "/A")])
    }

    @Test("Removing a child while the parent survives removes just the child")
    func removalOfChildOnly() {
        let before = ViewportScene([node("/A"), node("/A/B")])
        let after = ViewportScene([node("/A")])
        #expect(SceneGraphDiff.operations(from: before, to: after) == [.remove(path: "/A/B")])
    }

    @Test("Independent removed subtrees each emit their own root")
    func multipleRemovalRoots() {
        let before = ViewportScene([node("/A"), node("/A/B"), node("/X"), node("/X/Y")])
        let after = ViewportScene()
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.remove(path: "/A"), .remove(path: "/X")])
    }

    @Test("Removals are emitted before inserts")
    func removalsPrecedeInserts() {
        let before = ViewportScene([node("/Old")])
        let after = ViewportScene([node("/New")])
        let ops = SceneGraphDiff.operations(from: before, to: after)
        #expect(ops == [.remove(path: "/Old"), .insert(node("/New"))])
    }

    @Test("A moved prim emits a transform update and no re-mesh")
    func transformUpdateOnly() {
        let before = ViewportScene([node("/A", mesh: mesh())])
        let after = ViewportScene([node("/A", transform: translation(3), mesh: mesh())])
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.updateTransform(path: "/A", transform: translation(3))])
    }

    @Test("A topology change (new faces/verts) emits a full mesh update")
    func meshUpdate() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        let after = ViewportScene([node("/A", mesh: meshTopoChanged())])
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.updateMesh(path: "/A", mesh: meshTopoChanged())])
    }

    @Test("A positions-only edit on identical topology emits a partial vertex update")
    func positionsOnlyEmitsUpdateVertices() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        let after = ViewportScene([node("/A", mesh: mesh(9))])
        // mesh(0)→mesh(9) keeps faceLoops and vertex count; all three positions move.
        #expect(SceneGraphDiff.operations(from: before, to: after) == [
            .updateVertices(path: "/A", positions: [
                0: SIMD3(9, 0, 0), 1: SIMD3(10, 0, 0), 2: SIMD3(10, 1, 0),
            ]),
        ])
    }

    @Test("Only the vertices that actually moved appear in the partial update")
    func partialUpdateCarriesOnlyMovedVertices() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        var moved = mesh(0)
        moved.positions[1] = SIMD3(5, 5, 5) // move a single vertex
        let after = ViewportScene([node("/A", mesh: moved)])
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.updateVertices(path: "/A", positions: [1: SIMD3(5, 5, 5)])])
    }

    @Test("A vertex-count change is a topology change and falls back to re-mesh")
    func vertexCountChangeFallsBackToFullMesh() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        let after = ViewportScene([node("/A", mesh: meshTopoChanged())])
        let ops = SceneGraphDiff.operations(from: before, to: after)
        #expect(ops == [.updateMesh(path: "/A", mesh: meshTopoChanged())])
    }

    @Test("Geometry dropped from a prim updates the mesh to nil")
    func meshClearedToNil() {
        let before = ViewportScene([node("/A", mesh: mesh())])
        let after = ViewportScene([node("/A")])
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.updateMesh(path: "/A", mesh: nil)])
    }

    @Test("Hiding a prim toggles enablement without touching geometry")
    func enablementToggle() {
        let before = ViewportScene([node("/A", mesh: mesh())])
        let after = ViewportScene([node("/A", mesh: mesh(), isEnabled: false)])
        #expect(SceneGraphDiff.operations(from: before, to: after)
                == [.setEnabled(path: "/A", isEnabled: false)])
    }

    @Test("A prim changed in every dimension emits geometry, transform, then enablement")
    func combinedUpdatesAreOrdered() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        let after = ViewportScene([node("/A", transform: translation(2),
                                        mesh: meshTopoChanged(), isEnabled: false)])
        #expect(SceneGraphDiff.operations(from: before, to: after) == [
            .updateMesh(path: "/A", mesh: meshTopoChanged()),
            .updateTransform(path: "/A", transform: translation(2)),
            .setEnabled(path: "/A", isEnabled: false),
        ])
    }

    @Test("A positions-only edit composes with transform and enablement in order")
    func partialUpdateComposesWithOtherDimensions() {
        let before = ViewportScene([node("/A", mesh: mesh(0))])
        let after = ViewportScene([node("/A", transform: translation(2),
                                        mesh: mesh(1), isEnabled: false)])
        let ops = SceneGraphDiff.operations(from: before, to: after)
        #expect(ops.count == 3)
        guard case .updateVertices(let p, _) = ops[0] else { Issue.record("expected updateVertices first"); return }
        #expect(p == "/A")
        #expect(ops[1] == .updateTransform(path: "/A", transform: translation(2)))
        #expect(ops[2] == .setEnabled(path: "/A", isEnabled: false))
    }

    @Test("Updates across several survivors are emitted in a stable path order")
    func updateOrderIsStable() {
        let before = ViewportScene([node("/Zebra"), node("/Apple"), node("/Mango")])
        let after = ViewportScene([node("/Zebra", transform: translation(1)),
                                   node("/Apple", transform: translation(1)),
                                   node("/Mango", transform: translation(1))])
        let paths = SceneGraphDiff.operations(from: before, to: after).map { op -> String in
            guard case .updateTransform(let p, _) = op else { return "?" }
            return p
        }
        #expect(paths == ["/Apple", "/Mango", "/Zebra"])
    }

    @Test("Removals, inserts and updates compose in one pass")
    func mixedDiff() {
        let before = ViewportScene([node("/Keep", mesh: mesh(0)), node("/Drop")])
        let after = ViewportScene([node("/Keep", mesh: mesh(0), isEnabled: false),
                                   node("/Add", mesh: mesh(2))])
        #expect(SceneGraphDiff.operations(from: before, to: after) == [
            .remove(path: "/Drop"),
            .insert(node("/Add", mesh: mesh(2))),
            .setEnabled(path: "/Keep", isEnabled: false),
        ])
    }

    @Test("Seeding an empty viewport inserts the whole file tree")
    func seedFromEmpty() {
        let after = ViewportScene([node("/Model"), node("/Model/Geo", mesh: mesh())])
        let ops = SceneGraphDiff.operations(from: ViewportScene(), to: after)
        #expect(ops == [.insert(node("/Model")), .insert(node("/Model/Geo", mesh: mesh()))])
    }

    @Test("Closing a document removes everything")
    func teardownToEmpty() {
        let before = ViewportScene([node("/Model"), node("/Model/Geo")])
        #expect(SceneGraphDiff.operations(from: before, to: ViewportScene())
                == [.remove(path: "/Model")])
    }
}
