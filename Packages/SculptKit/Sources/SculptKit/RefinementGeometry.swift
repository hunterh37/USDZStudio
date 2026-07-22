import Foundation
import MeshKit
import simd

// Sculpt-accuracy P4 (#85): geometry expressiveness beyond primitives + inset.
//
// `MeshRefinement` (this module) carries only declarative intent; this resolver
// turns each op into a deterministic MeshKit selection + op over the authored
// mesh. It lives in SculptKit next to the intent so both executors — the
// AgentMCP tool pipeline and the in-app `SculptBuildRunner` — share one
// implementation. Determinism matters: the same spec must always produce the
// same topology, so every derived selection is built in a stable, sorted order
// — never from hash-map iteration order.
public enum RefinementGeometry {

    /// Taper: scale the cross-section linearly along `axis` — 1× at the low
    /// end, `scale`× at the high end — via a fitted 2×2×2 FFD lattice with the
    /// high-end control layer scaled about its centre. The wedge op.
    public static func taper(_ mesh: HalfEdgeMesh, axis: RefinementAxis, scale: Double) throws -> HalfEdgeMesh {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for p in mesh.positions.values {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        // Pad flat extents (a plane) so the cage keeps a positive rest volume;
        // the pad is far below any authored feature size.
        let eps = 1e-6
        let size = SIMD3(max(hi.x - lo.x, eps), max(hi.y - lo.y, eps), max(hi.z - lo.z, eps))
        var cage = LatticeCage.fitted(min: lo, max: lo + size)

        // Control-point grid order is i-fastest (S/x), then j (T/y), then k
        // (U/z) — see `LatticeCage.restGrid`. Pick the high layer along `axis`
        // and scale its points about the layer centre in the two cross axes.
        let r = cage.resolution
        func gridIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { k * (r.m * r.l) + j * r.l + i }
        var layer: [Int] = []
        for k in 0..<r.n {
            for j in 0..<r.m {
                for i in 0..<r.l {
                    let onHighLayer: Bool
                    switch axis {
                    case .x: onHighLayer = i == r.l - 1
                    case .y: onHighLayer = j == r.m - 1
                    case .z: onHighLayer = k == r.n - 1
                    }
                    if onHighLayer { layer.append(gridIndex(i, j, k)) }
                }
            }
        }
        var centre = SIMD3<Double>()
        for index in layer { centre += cage.controlPoints[index] }
        centre /= Double(layer.count)
        for index in layer {
            let p = cage.controlPoints[index]
            var scaled = centre + (p - centre) * scale
            // The taper axis itself is untouched — only the cross-section scales.
            switch axis {
            case .x: scaled.x = p.x
            case .y: scaled.y = p.y
            case .z: scaled.z = p.z
            }
            cage.controlPoints[index] = scaled
        }

        return try LatticeDeform.apply(
            mesh, selection: .vertices(Set(mesh.positions.keys)),
            params: .init(cage: cage)).mesh
    }

    /// Bevel/chamfer: every interior edge whose faces meet at a dihedral angle
    /// above `angleDegrees` is a candidate; MeshKit's v1 bevel requires the
    /// selection to be pairwise non-adjacent, so a deterministic greedy pass
    /// (sorted by vertex ids) picks a maximal independent subset to chamfer.
    public static func bevel(_ mesh: HalfEdgeMesh, width: Double, angleDegrees: Double) throws -> HalfEdgeMesh {
        let byEdge = mesh.edgeFaceMap
        let threshold = angleDegrees * .pi / 180
        var candidates: [EdgeKey] = []
        for (edge, faces) in byEdge where faces.count == 2 {
            let n0 = mesh.faceNormalArea(faces[0])
            let n1 = mesh.faceNormalArea(faces[1])
            let cosine = simd_dot(n0, n1) / (simd_length(n0) * simd_length(n1))
            // acos of a clamped cosine; a degenerate (zero-area) face yields
            // NaN, which fails the comparison and is skipped — never selected.
            let angle = acos(min(1, max(-1, cosine)))
            if angle > threshold { candidates.append(edge) }
        }
        // Deterministic order, then greedy non-adjacency.
        candidates.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        var used = Set<VertexID>()
        var selected = Set<EdgeKey>()
        for edge in candidates where !used.contains(edge.a) && !used.contains(edge.b) {
            selected.insert(edge)
            used.insert(edge.a)
            used.insert(edge.b)
        }
        guard !selected.isEmpty else {
            throw MeshOpError.preconditionFailed(
                "no edges sharper than \(angleDegrees)° to bevel")
        }
        return try BevelEdges.apply(mesh, selection: .edges(selected), params: .init(width: width)).mesh
    }

    /// Directional extrude: pull the faces whose outward normal aligns with
    /// `direction` (within 60°) by `distance` along that direction — splitters,
    /// intakes, cabin bulges. Negative distance recesses the region.
    public static func extrude(_ mesh: HalfEdgeMesh, direction: RefinementDirection, distance: Double) throws -> HalfEdgeMesh {
        let unit = direction.unitVector
        let dir = SIMD3(unit.x, unit.y, unit.z)
        var region = Set<FaceID>()
        for face in mesh.faceLoops.keys {
            let n = mesh.faceNormalArea(face)
            let length = simd_length(n)
            // Alignment against the *unit* normal; NaN from a zero-area face
            // fails the comparison and the face is skipped.
            if simd_dot(n / length, dir) > 0.5 { region.insert(face) }
        }
        guard !region.isEmpty else {
            throw MeshOpError.preconditionFailed(
                "no faces facing \(direction.rawValue) to extrude")
        }
        return try ExtrudeFaces.apply(
            mesh, selection: .faces(region),
            params: .init(distance: distance, direction: .axis(dir))).mesh
    }
}
