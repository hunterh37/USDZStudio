import Testing
import Foundation
@testable import MeshKit

// MARK: - Minimal .usda reader for the committed golden fixtures

/// Reads the controlled golden-fixture dialect only (single mesh prim, flat
/// attribute arrays, optional faceVarying st + GeomSubsets). Production usda
/// parsing lives in USDBridge; this exists so MeshKit's goldens stay
/// committed, reviewable text (specs/mesh-editing.md §Golden-mesh fixtures).
enum GoldenUsda {

    static func load(_ name: String) throws -> FlatMesh {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "usda",
                                                 subdirectory: "Golden"))
        let text = try String(contentsOf: url, encoding: .utf8)

        func doubles(after attribute: String) -> [Double] {
            guard let range = text.range(of: attribute),
                  let open = text.range(of: "[", range: range.upperBound..<text.endIndex),
                  let close = text.range(of: "]", range: open.upperBound..<text.endIndex)
            else { return [] }
            return text[open.upperBound..<close.lowerBound]
                .components(separatedBy: CharacterSet(charactersIn: "(), \n"))
                .compactMap(Double.init)
        }

        let p = doubles(after: "point3f[] points =")
        let counts = doubles(after: "int[] faceVertexCounts =").map(Int.init)
        let indices = doubles(after: "int[] faceVertexIndices =").map(Int.init)
        let st = doubles(after: "texCoord2f[] primvars:st =")

        var subsets: [String: [Int]] = [:]
        var cursor = text.startIndex
        while let def = text.range(of: "def GeomSubset \"", range: cursor..<text.endIndex) {
            let nameEnd = text.range(of: "\"", range: def.upperBound..<text.endIndex)!
            let subsetName = String(text[def.upperBound..<nameEnd.lowerBound])
            let idx = text.range(of: "int[] indices =", range: nameEnd.upperBound..<text.endIndex)!
            let open = text.range(of: "[", range: idx.upperBound..<text.endIndex)!
            let close = text.range(of: "]", range: open.upperBound..<text.endIndex)!
            subsets[subsetName] = text[open.upperBound..<close.lowerBound]
                .components(separatedBy: CharacterSet(charactersIn: ", \n"))
                .compactMap(Int.init)
            cursor = close.upperBound
        }

        return FlatMesh(
            points: stride(from: 0, to: p.count, by: 3).map { SIMD3(p[$0], p[$0 + 1], p[$0 + 2]) },
            faceVertexCounts: counts,
            faceVertexIndices: indices,
            faceVaryingUVs: stride(from: 0, to: st.count, by: 2).map { SIMD2(st[$0], st[$0 + 1]) },
            subsets: subsets)
    }
}

// MARK: - Golden-mesh snapshot tests

/// Committed .usda goldens covering the spec's known nasty cases; the pinned
/// literals below are the reviewed topology/attribute snapshots. If an op or
/// IO change shifts any value, the diff shows up here and in the .usda — both
/// reviewed in PR.
@Suite("Golden meshes")
struct GoldenMeshTests {

    // MARK: Bowtie vertex

    @Test func bowtieGolden_topologySnapshot_andExtrudeRefusal() throws {
        let flat = try GoldenUsda.load("golden-bowtie")
        let mesh = try MeshIO.mesh(from: flat)
        // Snapshot: V8 E12 F5, open, bowtie at v0.
        #expect(mesh.vertexCount == 8)
        #expect(mesh.edgeCount == 12)
        #expect(mesh.faceCount == 5)
        #expect(MeshInvariants.eulerCharacteristic(of: mesh) == 1)
        #expect(mesh.vertexFaceMap[VertexID(0)]?.count == 5)

        // Extruding the fan across the bowtie must refuse loudly.
        let fan = Set((0..<4).map(FaceID.init))
        #expect {
            _ = try ExtrudeFaces.apply(mesh, selection: .faces(fan), params: .init(distance: 0.5))
        } throws: { error in
            guard case MeshOpError.preconditionFailed(let msg) = error else { return false }
            return msg.contains("bowtie")
        }
    }

    // MARK: Mixed tri/quad region

    @Test func mixedGolden_topologySnapshot_andRoundTrip() throws {
        let flat = try GoldenUsda.load("golden-mixed")
        let mesh = try MeshIO.mesh(from: flat)
        // Snapshot: V9 E14 F6 (2 quads + 4 tris), healthy open manifold.
        #expect(mesh.vertexCount == 9)
        #expect(mesh.edgeCount == 14)
        #expect(mesh.faceCount == 6)
        #expect(mesh.faceLoops.values.map(\.count).sorted() == [3, 3, 3, 3, 4, 4])
        try MeshInvariants.assertHealthy(mesh)
        // Untouched golden must round-trip bit-faithfully (IO invariant).
        #expect(MeshIO.flat(from: mesh) == flat)

        // Extrude across the tri/quad border: predicted delta must hold.
        // Quad 0 and tri 3 share edge (v1,v4) — the region border crosses the
        // tri/quad boundary.
        let region: Set<FaceID> = [FaceID(0), FaceID(3)]
        let result = try ExtrudeFaces.apply(mesh, selection: .faces(region),
                                            params: .init(distance: 1))
        try MeshInvariants.assertHealthy(result.mesh)
        #expect(result.delta.eulerDelta == MeshInvariants.eulerCharacteristic(of: result.mesh)
                - MeshInvariants.eulerCharacteristic(of: mesh))
    }

    // MARK: UV seam crossing a selection boundary

    @Test func uvSeamGolden_untouchedFaceUVsStayByteIdentical() throws {
        let flat = try GoldenUsda.load("golden-uv-seam")
        let mesh = try MeshIO.mesh(from: flat)
        // Snapshot: 2 quads, seam on shared edge (v1,v4): left face ends at
        // u=0.5 while the right face restarts at u=0.75.
        #expect(mesh.faceCount == 2)
        #expect(mesh.faceCornerUVs[FaceID(0)]?[1] == SIMD2(0.5, 0))
        #expect(mesh.faceCornerUVs[FaceID(1)]?[0] == SIMD2(0.75, 0))
        #expect(MeshIO.flat(from: mesh) == flat)

        // Inset the left quad only: the right quad's UV corners must not move.
        let before = mesh.faceCornerUVs[FaceID(1)]
        let result = try InsetFaces.apply(mesh, selection: .faces([FaceID(0)]),
                                          params: .init(fraction: 0.25))
        #expect(result.mesh.faceCornerUVs[FaceID(1)] == before)
    }

    // MARK: GeomSubset borders

    @Test func subsetsGolden_membershipSurvivesOpsAndEmptiedSubsetsDrop() throws {
        let flat = try GoldenUsda.load("golden-subsets")
        let mesh = try MeshIO.mesh(from: flat)
        // Snapshot: cube, lid = face 1, shell = the other five.
        #expect(mesh.subsets["lid"] == [FaceID(1)])
        #expect(mesh.subsets["shell"]?.count == 5)
        #expect(abs(mesh.signedVolume - 1.0) < MeshInvariants.epsilon)
        #expect(MeshIO.flat(from: mesh) == flat)

        // Delete the lid: subset border collapses, export drops the empty set.
        let result = try DeleteComponents.apply(mesh, selection: .faces([FaceID(1)]))
        let exported = MeshIO.flat(from: result.mesh)
        #expect(exported.subsets["lid"] == nil)
        #expect(exported.subsets["shell"]?.count == 5)
    }
}
