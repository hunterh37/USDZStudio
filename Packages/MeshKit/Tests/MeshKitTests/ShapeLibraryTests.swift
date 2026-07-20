import Testing
import Foundation
@testable import MeshKit

/// The built-in library must be well-formed (unique ids, both groups
/// populated) and every entry must produce a healthy mesh: manifold, lossless
/// through MeshIO, and — for everything but the open plane — a closed,
/// positive-volume solid.
@Suite("ShapeLibrary")
struct ShapeLibraryTests {

    /// The plane is the only intentionally open primitive.
    private let openEntryIDs: Set<String> = ["prim.plane"]

    @Test func bothGroupsPopulated() {
        #expect(!ShapeLibrary.entries(in: .primitives).isEmpty)
        #expect(!ShapeLibrary.entries(in: .prefabs).isEmpty)
    }

    @Test func idsAreUnique() {
        let ids = ShapeLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func categoriesAreOrderedAndComplete() {
        for group in LibraryGroup.allCases {
            let categories = ShapeLibrary.categories(in: group)
            #expect(!categories.isEmpty)
            // Every entry's category is listed, and no category is empty.
            for category in categories {
                #expect(!ShapeLibrary.entries(in: group, category: category).isEmpty)
            }
            let listed = Set(categories)
            for entry in ShapeLibrary.entries(in: group) {
                #expect(listed.contains(entry.category))
            }
        }
    }

    @Test func everyEntryBuildsAndIsManifold() throws {
        for entry in ShapeLibrary.all {
            let mesh = try entry.build()
            #expect(mesh.faceCount > 0, "\(entry.id) has no faces")
            #expect(MeshInvariants.violations(in: mesh, allowBoundaries: true).isEmpty,
                    "\(entry.id) is non-manifold")
            // Lossless USD round-trip, the CI invariant Primitives also holds.
            let flat = MeshIO.flat(from: mesh)
            let back = try MeshIO.mesh(from: flat)
            #expect(MeshIO.flat(from: back) == flat, "\(entry.id) did not round-trip")
        }
    }

    @Test func solidEntriesAreWatertightAndOutward() throws {
        for entry in ShapeLibrary.all where !openEntryIDs.contains(entry.id) {
            let mesh = try entry.build()
            #expect(MeshInvariants.violations(in: mesh, allowBoundaries: false).isEmpty,
                    "\(entry.id) is not closed")
            #expect(mesh.signedVolume > 0, "\(entry.id) has non-positive volume (inward winding)")
        }
    }

    @Test func entryLookupByID() {
        #expect(ShapeLibrary.entry(id: "prim.cube")?.name == "Cube")
        #expect(ShapeLibrary.entry(id: "prefab.tree")?.group == .prefabs)
        #expect(ShapeLibrary.entry(id: "nope") == nil)
    }
}

/// Compositing helpers preserve the Primitives contract.
@Suite("MeshCompositing")
struct MeshCompositingTests {

    @Test func translatePreservesTopologyAndShiftsVolumeCentroid() throws {
        let box = try Primitives.box()
        let moved = box.translated(by: SIMD3(5, 0, 0))
        #expect(moved.faceCount == box.faceCount)
        #expect(moved.vertexCount == box.vertexCount)
        // Volume is translation-invariant.
        #expect(abs(moved.signedVolume - box.signedVolume) < 1e-9)
    }

    @Test func positiveScaleKeepsOutwardWinding() throws {
        let scaled = try Primitives.uvSphere().scaled(by: SIMD3(2, 0.5, 1.5))
        #expect(scaled.signedVolume > 0)
        #expect(MeshInvariants.violations(in: scaled, allowBoundaries: false).isEmpty)
    }

    @Test func rotationPreservesVolume() throws {
        let box = try Primitives.box(width: 2, height: 1, depth: 3)
        let rotated = box.rotatedY(.pi / 3)
        #expect(abs(rotated.signedVolume - box.signedVolume) < 1e-9)
    }

    @Test func mergeIsDisjointUnion() throws {
        let a = try Primitives.box()
        let b = try Primitives.box().translated(by: SIMD3(3, 0, 0))
        let merged = HalfEdgeMesh.merged([a, b])
        #expect(merged.vertexCount == a.vertexCount + b.vertexCount)
        #expect(merged.faceCount == a.faceCount + b.faceCount)
        #expect(MeshInvariants.violations(in: merged, allowBoundaries: false).isEmpty)
        // Two unit cubes → Euler characteristic 2 per component = 4.
        #expect(MeshInvariants.eulerCharacteristic(of: merged) == 4)
        #expect(abs(merged.signedVolume - 2 * a.signedVolume) < 1e-9)
    }
}
