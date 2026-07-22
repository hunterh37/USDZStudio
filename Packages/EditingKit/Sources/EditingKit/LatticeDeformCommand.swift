import USDCore
import MeshKit

/// Bake a lattice (FFD) cage deformation into a mesh prim's geometry as one
/// coalesced, undoable command (specs/mesh-editing.md §Lattice deformer;
/// research/topics/lattice-deformer). A lattice deform touches only vertex
/// positions — topology is untouched — so this writes just `points` (and
/// recomputed `normals`) rather than a whole `FlatMesh`, restoring the exact
/// prior attributes on undo via the shared `AttributeUndo` inverse.
///
/// The deformed positions are ordinary mesh data, so the result exports clean
/// under the RealityKit `arkit` profile with nothing to flag — the cage itself
/// is authoring state and is never written to USD (there is no lattice schema).
public struct LatticeDeformCommand: EditCommand {
    public let path: PrimPath
    /// Flat `[x, y, z, …]` deformed positions.
    let newPoints: [Double]
    /// Flat recomputed vertex normals, or `nil` when the topology cannot yield
    /// honest normals (then the existing normals attribute is left untouched).
    let newNormals: [Double]?
    let pointsUndo: AttributeUndo
    let normalsUndo: AttributeUndo?

    public var label: String { "Lattice Deform (\(path.name))" }

    init(path: PrimPath, newPoints: [Double], newNormals: [Double]?,
         pointsUndo: AttributeUndo, normalsUndo: AttributeUndo?) {
        self.path = path
        self.newPoints = newPoints
        self.newNormals = newNormals
        self.pointsUndo = pointsUndo
        self.normalsUndo = normalsUndo
    }

    /// Build the command for `path` under `cage`, reading the mesh's current
    /// geometry from `stage`.
    ///
    /// Runs the deformation through `MeshKit.LatticeDeform`, so a degenerate cage
    /// or a fold that would collapse a face throws (loud refusal, never silent
    /// garbage). Skinned meshes are refused — baking positions would desync skin
    /// weights — mirroring every other mesh op.
    public static func make(path: PrimPath,
                            cage: LatticeCage,
                            in stage: any USDStageProtocol) throws -> LatticeDeformCommand {
        guard let prim = stage.prim(at: path), prim.typeName == "Mesh" else {
            throw MeshOpError.preconditionFailed("prim at \(path) is not a mesh")
        }
        guard !isSkinned(prim) else { throw MeshOpError.skinnedMeshUnsupported }

        guard let flatPoints = MeshNormals.points(of: prim),
              let counts = MeshNormals.intArray(prim, "faceVertexCounts"),
              let indices = MeshNormals.intArray(prim, "faceVertexIndices") else {
            throw MeshOpError.preconditionFailed("mesh \(path.name) is missing points/topology")
        }
        guard flatPoints.count % 3 == 0 else {
            throw MeshOpError.preconditionFailed("mesh \(path.name) has a malformed points array")
        }

        var points: [SIMD3<Double>] = []
        points.reserveCapacity(flatPoints.count / 3)
        for i in stride(from: 0, to: flatPoints.count, by: 3) {
            points.append(SIMD3(flatPoints[i], flatPoints[i + 1], flatPoints[i + 2]))
        }
        let flat = FlatMesh(points: points, faceVertexCounts: counts, faceVertexIndices: indices)

        // Route through the MeshKit op: validates the cage, bakes positions, and
        // verifies topology/manifold invariants held.
        let mesh = try MeshIO.mesh(from: flat)
        let result = try LatticeDeform.apply(mesh, selection: .faces(Set(mesh.faceOrder)),
                                             params: .init(cage: cage))
        let deformed = MeshIO.flat(from: result.mesh)

        var newPoints: [Double] = []
        newPoints.reserveCapacity(deformed.points.count * 3)
        for p in deformed.points { newPoints += [p.x, p.y, p.z] }

        // Recompute area-weighted normals for the deformed surface. A mesh that
        // survived `MeshIO.mesh(from:)` has valid topology, so this is always
        // non-empty; the optional `newNormals` API (and its nil handling in
        // execute/undo) exists for other callers and is exercised directly.
        let newNormals = VertexNormals.smoothFlat(for: deformed)

        return LatticeDeformCommand(
            path: path,
            newPoints: newPoints,
            newNormals: newNormals,
            pointsUndo: AttributeUndo(path: path, name: "points",
                                      previous: prim.attribute(named: "points")),
            normalsUndo: AttributeUndo(path: path, name: "normals",
                                       previous: prim.attribute(named: "normals")))
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setAttribute(path: path,
            attribute: Attribute(name: "points", value: .float3Array(newPoints))))
        if let newNormals {
            try stage.apply(.setAttribute(path: path,
                attribute: Attribute(name: "normals", value: .float3Array(newNormals),
                                     metadata: ["interpolation": "\"vertex\""])))
        }
    }

    public func undo(on stage: any USDStageMutable) throws {
        try pointsUndo.revert(on: stage)
        try normalsUndo?.revert(on: stage)
    }

    /// A mesh is skinned if it carries UsdSkel joint weights/indices — baking
    /// positions under a lattice would break those weights.
    static func isSkinned(_ prim: Prim) -> Bool {
        prim.attribute(named: "primvars:skel:jointWeights") != nil
            || prim.attribute(named: "primvars:skel:jointIndices") != nil
    }
}
