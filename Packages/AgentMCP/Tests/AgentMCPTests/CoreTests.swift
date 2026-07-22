import Foundation
import Testing
import USDCore
@testable import AgentMCP

@Suite struct PrimIDRegistryTests {

    @Test func mintsStableIDs() {
        var registry = PrimIDRegistry()
        let path = PrimPath("/A/B")!
        let id = registry.id(for: path)
        #expect(registry.id(for: path) == id)
        #expect(registry.path(for: id) == path)
        #expect(registry.path(for: "prim-999") == nil)
        #expect(registry.handles.count == 1)
    }

    @Test func moveTracksSubtree() {
        var registry = PrimIDRegistry()
        let parent = registry.id(for: PrimPath("/Table")!)
        let child = registry.id(for: PrimPath("/Table/Leg")!)
        registry.move(from: PrimPath("/Table")!, to: PrimPath("/Furniture/Desk")!)
        #expect(registry.path(for: parent) == PrimPath("/Furniture/Desk")!)
        #expect(registry.path(for: child) == PrimPath("/Furniture/Desk/Leg")!)
    }

    @Test func invalidateKillsSubtreeForever() {
        var registry = PrimIDRegistry()
        let id = registry.id(for: PrimPath("/A/B")!)
        let other = registry.id(for: PrimPath("/C")!)
        registry.invalidate(subtree: PrimPath("/A")!)
        #expect(registry.path(for: id) == nil)
        #expect(registry.path(for: other) == PrimPath("/C")!)
        // New handle for the same path is a new id.
        #expect(registry.id(for: PrimPath("/A/B")!) != id)
    }
}

@Suite struct StageDiffTests {

    @Test func detectsAddRemoveModify() {
        let before = Fixtures.snapshot()
        var after = before
        // Remove /Root/Lid, add /Root/New, modify /Root/Box attribute.
        var root = after.rootPrims[0]
        root.children.removeAll { $0.name == "Lid" }
        root.children.append(Prim(path: PrimPath("/Root/New")!, typeName: "Scope"))
        root.children[0].attributes.append(Attribute(name: "custom", value: .int(1)))
        after.rootPrims = [root]
        after.metadata.metersPerUnit = 0.01

        let diff = StageDiff.compute(before: before, after: after)
        #expect(diff.addedPrims == [PrimPath("/Root/New")!])
        #expect(diff.removedPrims == [PrimPath("/Root/Lid")!])
        #expect(diff.modifiedPrims == [PrimPath("/Root/Box")!])
        #expect(diff.changedAttributes[PrimPath("/Root/Box")!] == ["custom"])
        #expect(diff.metadataChanged)
        #expect(!diff.isEmpty)

        let json = diff.asJSON
        #expect(json["added"].arrayValue?.first?.stringValue == "/Root/New")
        #expect(json["metadataChanged"].boolValue == true)
    }

    @Test func removedAttributeCountsAsChange() {
        let before = Fixtures.snapshot()
        var after = before
        after.rootPrims[0].children[0].attributes.removeAll { $0.name == "points" }
        let diff = StageDiff.compute(before: before, after: after)
        #expect(diff.changedAttributes[PrimPath("/Root/Box")!] == ["points"])
    }

    @Test func identicalSnapshotsDiffEmpty() {
        let snapshot = Fixtures.snapshot()
        #expect(StageDiff.compute(before: snapshot, after: snapshot).isEmpty)
    }
}

@Suite struct GeometryProbeTests {

    @Test func worldBBoxAndUnionAndVolume() {
        let session = Fixtures.session()
        let box = GeometryProbe.worldBBox(of: PrimPath("/Root/Box")!, in: session.stage)!
        #expect(abs(box.maxExtent - 1.0) < 1e-9)
        #expect(box.center == [0, 0, 0])
        // Lid is translated up by 3.
        let lid = GeometryProbe.worldBBox(of: PrimPath("/Root/Lid")!, in: session.stage)!
        #expect(abs(lid.center[1] - 3) < 1e-9)
        let whole = GeometryProbe.worldBBox(of: PrimPath("/Root")!, in: session.stage)!
        #expect(abs(whole.size[1] - 4) < 1e-9)
        #expect(box.overlapVolume(with: lid) == 0)
        #expect(box.overlapVolume(with: box) > 0.99)
        #expect(GeometryProbe.worldBBox(of: PrimPath("/Nope")!, in: session.stage) == nil)
        #expect(box.asJSON["size"].doubleArrayValue?.count == 3)
    }

    @Test func flatMeshExtractionAndErrors() throws {
        let session = Fixtures.session()
        let prim = session.stage.prim(at: PrimPath("/Root/Box")!)!
        let flat = try GeometryProbe.flatMesh(of: prim)
        #expect(flat.points.count == 8)
        #expect(flat.faceVertexCounts.count == 6)

        let bare = Prim(path: PrimPath("/X")!, typeName: "Xform")
        #expect(throws: ToolError.self) { _ = try GeometryProbe.flatMesh(of: bare) }
    }

    /// A mesh whose `points`/topology are authored as a flat `double[]`
    /// (`.doubleArray`) — the encoding a reopened externally authored USDZ can
    /// carry — must still be visible to the probe: bounds compute and
    /// `flatMesh` extraction succeed exactly as for canonical `point3f[]`.
    /// Regression guard for imported/double-precision meshes reading as empty.
    @Test func doublePrecisionPointsRemainVisible() throws {
        // Unit tetrahedron with double[]-typed points and normals.
        let tetra = Prim(
            path: PrimPath("/Root/Tetra")!,
            typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .doubleArray([
                    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1,
                ])),
                Attribute(name: "faceVertexCounts", value: .intArray([3, 3, 3, 3])),
                Attribute(name: "faceVertexIndices", value: .intArray([
                    0, 1, 2, 0, 1, 3, 1, 2, 3, 2, 0, 3,
                ])),
            ])
        let snapshot = StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: "Root"),
            rootPrims: [
                Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [tetra])
            ])
        let session = EditSession(snapshot: snapshot, strictness: .warn)
        // Bounds see the geometry (previously nil for double[]).
        let box = GeometryProbe.worldBBox(of: PrimPath("/Root/Tetra")!, in: session.stage)!
        #expect(abs(box.maxExtent - 1.0) < 1e-9)
        // And it extracts as a real mesh rather than throwing "no topology".
        let flat = try GeometryProbe.flatMesh(of: tetra)
        #expect(flat.points.count == 4)
    }

    @Test func raycastHitsNearestMesh() {
        let session = Fixtures.session()
        // Shoot straight down from above: should hit the Lid (at y≈3.5) first.
        let hit = GeometryProbe.raycast(origin: [0, 10, 0], direction: [0, -1, 0], in: session.stage)
        #expect(hit?.path == PrimPath("/Root/Lid")!)
        #expect(abs((hit?.distance ?? 0) - 6.5) < 1e-6)
        // Miss entirely.
        #expect(GeometryProbe.raycast(origin: [50, 50, 50], direction: [0, 1, 0], in: session.stage) == nil)
        // Degenerate direction.
        #expect(GeometryProbe.raycast(origin: [0, 0, 0], direction: [0, 0, 0], in: session.stage) == nil)
    }

    @Test func rayTriangleEdgeCases() {
        // Parallel ray → nil; behind origin → nil; inside → t.
        let a = [0.0, 0, 0], b = [1.0, 0, 0], c = [0.0, 1, 0]
        #expect(GeometryProbe.intersect(origin: [0.2, 0.2, 1], dir: [0, 0, -1], a: a, b: b, c: c) == 1)
        #expect(GeometryProbe.intersect(origin: [0.2, 0.2, 1], dir: [0, 0, 1], a: a, b: b, c: c) == nil)
        #expect(GeometryProbe.intersect(origin: [0, 0, 1], dir: [1, 0, 0], a: a, b: b, c: c) == nil)
        #expect(GeometryProbe.intersect(origin: [5, 5, 1], dir: [0, 0, -1], a: a, b: b, c: c) == nil)
        #expect(GeometryProbe.intersect(origin: [-1, 0.2, 1], dir: [0, 0, -1], a: a, b: b, c: c) == nil)
    }

    @Test func interpenetrationDetection() {
        // Two overlapping boxes at the root.
        var snapshot = Fixtures.snapshot()
        var root = snapshot.rootPrims[0]
        var overlapping = root.children[0]
        overlapping.path = PrimPath("/Root/Box2")!
        root.children.append(overlapping)
        snapshot.rootPrims = [root]
        let session = EditSession(snapshot: snapshot)
        let overlaps = GeometryProbe.interpenetrations(in: session.stage)
        #expect(overlaps.count == 1)
        #expect(overlaps[0].overlapVolume > 0.9)
        // Original fixture (disjoint) has none.
        #expect(GeometryProbe.interpenetrations(in: Fixtures.session().stage).isEmpty)
    }
}
