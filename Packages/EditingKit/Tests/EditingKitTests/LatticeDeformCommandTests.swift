import Testing
import Foundation
import USDCore
import MeshKit
@testable import EditingKit

/// Lattice/FFD bake command (specs/mesh-editing.md §Lattice deformer). Verifies
/// the deformed `points`/`normals` are authored as one coalesced, exactly
/// invertible command, and that the factory refuses bad inputs loudly.
@Suite("LatticeDeformCommand")
struct LatticeDeformCommandTests {

    private let path = PrimPath("/Root/Panel")!

    /// Unit-cube mesh prim, optionally carrying prior normals / a skin binding.
    private func cubePrim(normals: [Double]? = nil, skinned: Bool = false) -> Prim {
        var attrs: [Attribute] = [
            Attribute(name: "points", value: .float3Array([
                0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1])),
            Attribute(name: "faceVertexCounts", value: .intArray([4,4,4,4,4,4])),
            Attribute(name: "faceVertexIndices", value: .intArray([
                0,3,2,1, 4,5,6,7, 0,1,5,4, 1,2,6,5, 2,3,7,6, 3,0,4,7])),
        ]
        if let normals { attrs.append(Attribute(name: "normals", value: .float3Array(normals))) }
        if skinned { attrs.append(Attribute(name: "primvars:skel:jointWeights", value: .float3Array([]))) }
        return Prim(path: path, typeName: "Mesh", attributes: attrs)
    }

    private func stage(_ prim: Prim) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: [Prim(path: PrimPath("/Root")!, typeName: "Xform",
                                                     children: [prim])]))
    }

    /// A shear cage that actually moves the cube's corners.
    private func shearCage() -> LatticeCage {
        var cage = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1), interpolation: .trilinear)
        cage.controlPoints = cage.controlPoints.map { $0 + SIMD3(0.5 * $0.y, 0, 0) }
        return cage
    }

    @Test("make → execute authors deformed points + normals; undo removes freshly-authored normals")
    func executeAndUndoNoPriorNormals() throws {
        let s = stage(cubePrim())
        let cmd = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        #expect(cmd.label == "Lattice Deform (Panel)")

        try cmd.execute(on: s)
        let prim = try #require(s.prim(at: path))
        guard case .float3Array(let pts)? = prim.attribute(named: "points")?.value else {
            Issue.record("points not authored"); return
        }
        #expect(pts.count == 24)
        // Top face sheared +x: the vertex at (0,1,0) → x ≈ 0.5.
        #expect(abs(pts[9] - 0.5) < 1e-9)          // point index 3 = (0,1,0), x component
        #expect(prim.attribute(named: "normals") != nil)

        try cmd.undo(on: s)
        let after = try #require(s.prim(at: path))
        guard case .float3Array(let restored)? = after.attribute(named: "points")?.value else {
            Issue.record("points not restored"); return
        }
        #expect(restored[9] == 0)                   // original (0,1,0)
        // Normals did not exist before → undo removes them (AttributeUndo remove path).
        #expect(after.attribute(named: "normals") == nil)
    }

    @Test("undo restores prior normals when the mesh already had them")
    func undoRestoresPriorNormals() throws {
        let prior = [Double](repeating: 0.577, count: 24)
        let s = stage(cubePrim(normals: prior))
        let cmd = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        let after = try #require(s.prim(at: path))
        guard case .float3Array(let n)? = after.attribute(named: "normals")?.value else {
            Issue.record("normals not restored"); return
        }
        #expect(n == prior)
    }

    @Test("direct init supports the nil-normals path (execute + undo skip normals)")
    func nilNormalsPath() throws {
        let s = stage(cubePrim())
        let cmd = LatticeDeformCommand(
            path: path,
            newPoints: [Double](repeating: 0, count: 24),
            newNormals: nil,
            pointsUndo: AttributeUndo(path: path, name: "points",
                                      previous: s.prim(at: path)?.attribute(named: "points")),
            normalsUndo: nil)
        try cmd.execute(on: s)
        #expect(s.prim(at: path)?.attribute(named: "normals") == nil)
        try cmd.undo(on: s)                          // normalsUndo? == nil branch
        guard case .float3Array(let pts)? = s.prim(at: path)?.attribute(named: "points")?.value else {
            Issue.record("points not restored"); return
        }
        #expect(pts[0] == 0)
    }

    @Test("make refuses a non-mesh prim")
    func refusesNonMesh() {
        let s = InMemoryStage(StageSnapshot(rootPrims: [Prim(path: path, typeName: "Xform")]))
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        }
    }

    @Test("make refuses a skinned mesh")
    func refusesSkinned() {
        let s = stage(cubePrim(skinned: true))
        #expect(throws: MeshOpError.skinnedMeshUnsupported) {
            _ = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        }
    }

    @Test("make refuses a mesh missing geometry")
    func refusesMissingGeometry() {
        let bare = Prim(path: path, typeName: "Mesh",
                        attributes: [Attribute(name: "points", value: .float3Array([0,0,0]))])
        let s = stage(bare)
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        }
    }

    @Test("make refuses a malformed points array")
    func refusesMalformedPoints() {
        let bad = Prim(path: path, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([0, 0])),   // not a multiple of 3
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 0, 0])),
        ])
        let s = stage(bad)
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeformCommand.make(path: path, cage: shearCage(), in: s)
        }
    }

    @Test("make surfaces a degenerate-cage refusal")
    func refusesDegenerateCage() {
        let s = stage(cubePrim())
        var bad = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1))
        bad.controlPoints.removeLast()
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeformCommand.make(path: path, cage: bad, in: s)
        }
    }
}
