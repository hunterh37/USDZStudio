import Foundation

/// Flat-array mesh as USD authors it (UsdGeomMesh points / faceVertexCounts /
/// faceVertexIndices, plus the attribute channels we carry).
public struct FlatMesh: Equatable, Sendable {
    public var points: [SIMD3<Double>]
    public var faceVertexCounts: [Int]
    public var faceVertexIndices: [Int]
    /// Face-varying UVs, parallel to `faceVertexIndices`. Empty = channel absent.
    public var faceVaryingUVs: [SIMD2<Double>]
    /// GeomSubset name → face indices.
    public var subsets: [String: [Int]]
    /// True when the prim has `skel:skeleton` / joint weights bound.
    public var hasSkeletalBinding: Bool

    public init(points: [SIMD3<Double>],
                faceVertexCounts: [Int],
                faceVertexIndices: [Int],
                faceVaryingUVs: [SIMD2<Double>] = [],
                subsets: [String: [Int]] = [:],
                hasSkeletalBinding: Bool = false) {
        self.points = points
        self.faceVertexCounts = faceVertexCounts
        self.faceVertexIndices = faceVertexIndices
        self.faceVaryingUVs = faceVaryingUVs
        self.subsets = subsets
        self.hasSkeletalBinding = hasSkeletalBinding
    }
}

/// USD flat arrays ⇄ `HalfEdgeMesh`, lossless for untouched meshes
/// (import → export with no ops = identical arrays; CI invariant).
public enum MeshIO {

    public static func mesh(from flat: FlatMesh) throws -> HalfEdgeMesh {
        // v1: ops refuse on skinned meshes with a clear diagnostic (spec).
        guard !flat.hasSkeletalBinding else { throw MeshOpError.skinnedMeshUnsupported }
        guard flat.faceVertexCounts.reduce(0, +) == flat.faceVertexIndices.count else {
            throw MeshOpError.preconditionFailed(
                "faceVertexCounts sums to \(flat.faceVertexCounts.reduce(0, +)) but \(flat.faceVertexIndices.count) indices were authored")
        }
        let hasUVs = !flat.faceVaryingUVs.isEmpty
        if hasUVs, flat.faceVaryingUVs.count != flat.faceVertexIndices.count {
            throw MeshOpError.preconditionFailed("face-varying UV count ≠ face-vertex index count")
        }

        var mesh = HalfEdgeMesh()
        var vertexIDs: [VertexID] = []
        vertexIDs.reserveCapacity(flat.points.count)
        for p in flat.points { vertexIDs.append(mesh.addVertex(p)) }

        var cursor = 0
        var faceIDs: [FaceID] = []
        for count in flat.faceVertexCounts {
            guard count >= 3 else {
                throw MeshOpError.preconditionFailed("face with \(count) vertices")
            }
            let slice = flat.faceVertexIndices[cursor..<(cursor + count)]
            let loop = try slice.map { idx -> VertexID in
                guard idx >= 0, idx < vertexIDs.count else {
                    throw MeshOpError.unknownComponent("point index \(idx)")
                }
                return vertexIDs[idx]
            }
            let uvs = hasUVs ? Array(flat.faceVaryingUVs[cursor..<(cursor + count)]) : nil
            faceIDs.append(mesh.addFace(loop, uvs: uvs))
            cursor += count
        }

        var subsetSets: [String: Set<FaceID>] = [:]
        for (name, indices) in flat.subsets {
            var set = Set<FaceID>()
            for i in indices {
                guard i >= 0, i < faceIDs.count else {
                    throw MeshOpError.unknownComponent("subset '\(name)' face index \(i)")
                }
                set.insert(faceIDs[i])
            }
            subsetSets[name] = set
        }
        mesh.setSubsets(subsetSets)
        return mesh
    }

    public static func flat(from mesh: HalfEdgeMesh) -> FlatMesh {
        var pointIndex: [VertexID: Int] = [:]
        var points: [SIMD3<Double>] = []
        for v in mesh.vertexOrder {
            pointIndex[v] = points.count
            points.append(mesh.positions[v]!)
        }

        var counts: [Int] = []
        var indices: [Int] = []
        var uvs: [SIMD2<Double>] = []
        var allFacesHaveUVs = !mesh.faceOrder.isEmpty
        var faceIndex: [FaceID: Int] = [:]
        for (i, f) in mesh.faceOrder.enumerated() {
            faceIndex[f] = i
            let loop = mesh.faceLoops[f]!
            counts.append(loop.count)
            indices.append(contentsOf: loop.map { pointIndex[$0]! })
            if let faceUVs = mesh.faceCornerUVs[f] { uvs.append(contentsOf: faceUVs) }
            else { allFacesHaveUVs = false }
        }

        var subsets: [String: [Int]] = [:]
        for (name, faces) in mesh.subsets {
            let indices = faces.compactMap { faceIndex[$0] }.sorted()
            // An emptied subset (all member faces deleted) is not exported —
            // a GeomSubset with no indices is meaningless in USD.
            if !indices.isEmpty { subsets[name] = indices }
        }
        return FlatMesh(points: points,
                        faceVertexCounts: counts,
                        faceVertexIndices: indices,
                        faceVaryingUVs: allFacesHaveUVs ? uvs : [],
                        subsets: subsets)
    }
}
