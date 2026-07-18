import Foundation

/// Parametric low-poly primitive generators — the starting stock for
/// agent-driven box modeling (specs/mesh-editing.md is repair-focused; recipes
/// extend it to build-from-stock: primitive → op chain → export).
///
/// Contract, checked by `PrimitiveTests` for every generator and parameter
/// sweep:
/// - Every mesh passes `MeshInvariants` (closed primitives with
///   `allowBoundaries: false`).
/// - Winding is outward everywhere: `signedVolume > 0` and, for convex
///   primitives, every face normal points away from the centroid.
/// - Closed primitives are genus-0: V − E + F == 2.
/// - Vertex/edge/face counts match the closed-form formulas documented per
///   generator.
///
/// Conventions: Y-up, centered on the origin (plane sits at y = 0).
public enum Primitives {

    // MARK: - Plane

    /// Grid plane in XZ at y = 0, facing +Y.
    /// V = (sx+1)(sz+1), F = sx·sz, E = sx(sz+1) + sz(sx+1).
    public static func plane(width: Double = 1, depth: Double = 1,
                             segmentsX: Int = 1, segmentsZ: Int = 1) throws -> HalfEdgeMesh {
        try requirePositive(width, "width"); try requirePositive(depth, "depth")
        try require(segmentsX >= 1, "segmentsX must be ≥ 1")
        try require(segmentsZ >= 1, "segmentsZ must be ≥ 1")

        var mesh = HalfEdgeMesh()
        var grid: [[VertexID]] = []
        for i in 0...segmentsX {
            var row: [VertexID] = []
            for k in 0...segmentsZ {
                let x = width * (Double(i) / Double(segmentsX) - 0.5)
                let z = depth * (Double(k) / Double(segmentsZ) - 0.5)
                row.append(mesh.addVertex(SIMD3(x, 0, z)))
            }
            grid.append(row)
        }
        for i in 0..<segmentsX {
            for k in 0..<segmentsZ {
                // +Y normal: traverse so x-then-z edges give z×x = +y… verified
                // by tests: [i,k] → [i,k+1] → [i+1,k+1] → [i+1,k].
                mesh.addFace([grid[i][k], grid[i][k + 1], grid[i + 1][k + 1], grid[i + 1][k]])
            }
        }
        return mesh
    }

    // MARK: - Box

    /// Axis-aligned box centered at the origin with independent per-axis
    /// segment counts. Shared lattice vertices along edges/corners (welded).
    /// For s = (1,1,1): V 8, E 12, F 6.
    public static func box(width: Double = 1, height: Double = 1, depth: Double = 1,
                           segments: SIMD3<Int> = SIMD3(1, 1, 1)) throws -> HalfEdgeMesh {
        try requirePositive(width, "width"); try requirePositive(height, "height")
        try requirePositive(depth, "depth")
        try require(segments.x >= 1 && segments.y >= 1 && segments.z >= 1,
                    "segments must all be ≥ 1")

        let s = segments
        var mesh = HalfEdgeMesh()
        var lattice: [SIMD3<Int>: VertexID] = [:]

        func vertex(_ i: Int, _ j: Int, _ k: Int) -> VertexID {
            let key = SIMD3(i, j, k)
            if let v = lattice[key] { return v }
            let p = SIMD3(
                width * (Double(i) / Double(s.x) - 0.5),
                height * (Double(j) / Double(s.y) - 0.5),
                depth * (Double(k) / Double(s.z) - 0.5))
            let v = mesh.addVertex(p)
            lattice[key] = v
            return v
        }

        // Each closure maps a face-local (a, b) cell corner to lattice coords.
        // Winding is chosen per side so all normals point outward (verified by
        // the volume/normal tests).
        func side(_ aMax: Int, _ bMax: Int, flip: Bool,
                  _ point: (Int, Int) -> (Int, Int, Int)) {
            for a in 0..<aMax {
                for b in 0..<bMax {
                    let c00 = point(a, b), c10 = point(a + 1, b)
                    let c11 = point(a + 1, b + 1), c01 = point(a, b + 1)
                    let loop = [
                        vertex(c00.0, c00.1, c00.2),
                        vertex(c10.0, c10.1, c10.2),
                        vertex(c11.0, c11.1, c11.2),
                        vertex(c01.0, c01.1, c01.2),
                    ]
                    mesh.addFace(flip ? loop.reversed() : loop)
                }
            }
        }

        side(s.y, s.z, flip: false) { (s.x, $0, $1) }   // +X: y then z → outward
        side(s.y, s.z, flip: true) { (0, $0, $1) }      // −X
        side(s.z, s.x, flip: false) { ($1, s.y, $0) }   // +Y: z then x → outward
        side(s.z, s.x, flip: true) { ($1, 0, $0) }      // −Y
        side(s.x, s.y, flip: false) { ($0, $1, s.z) }   // +Z: x then y → outward
        side(s.x, s.y, flip: true) { ($0, $1, 0) }      // −Z
        return mesh
    }

    // MARK: - Cylinder

    /// Cylinder along Y, centered at the origin. Caps are single n-gons.
    /// V = n(h+1) + 0, F = n·h + 2, E = n(h+1) + n·h  (n = radialSegments,
    /// h = heightSegments), when capped.
    public static func cylinder(radius: Double = 0.5, height: Double = 1,
                                radialSegments: Int = 8, heightSegments: Int = 1,
                                capped: Bool = true) throws -> HalfEdgeMesh {
        try requirePositive(radius, "radius"); try requirePositive(height, "height")
        try require(radialSegments >= 3, "radialSegments must be ≥ 3")
        try require(heightSegments >= 1, "heightSegments must be ≥ 1")

        var mesh = HalfEdgeMesh()
        var rings: [[VertexID]] = []
        for r in 0...heightSegments {
            let y = height * (Double(r) / Double(heightSegments) - 0.5)
            rings.append(ring(&mesh, radius: radius, y: y, count: radialSegments))
        }
        for r in 0..<heightSegments {
            addTubeQuads(&mesh, lower: rings[r], upper: rings[r + 1])
        }
        if capped {
            mesh.addFace(rings[0])                              // bottom: +θ order → −Y
            mesh.addFace(rings[heightSegments].reversed())      // top: reversed → +Y
        }
        return mesh
    }

    // MARK: - Cone

    /// Cone along Y: base n-gon at y = −h/2, apex at +h/2.
    /// V = n + 1, F = n + 1, E = 2n.
    public static func cone(radius: Double = 0.5, height: Double = 1,
                            radialSegments: Int = 8) throws -> HalfEdgeMesh {
        try requirePositive(radius, "radius"); try requirePositive(height, "height")
        try require(radialSegments >= 3, "radialSegments must be ≥ 3")

        var mesh = HalfEdgeMesh()
        let base = ring(&mesh, radius: radius, y: -height / 2, count: radialSegments)
        let apex = mesh.addVertex(SIMD3(0, height / 2, 0))
        for i in 0..<radialSegments {
            let j = (i + 1) % radialSegments
            mesh.addFace([base[j], base[i], apex])   // outward (verified by tests)
        }
        mesh.addFace(base)                           // base: +θ order → −Y
        return mesh
    }

    // MARK: - UV sphere

    /// UV sphere: `rings` latitude divisions (≥ 2), `segments` longitude
    /// divisions (≥ 3). Poles are triangle fans.
    /// V = segments·(rings−1) + 2, F = segments·rings,
    /// E = segments·(rings−1) + segments·rings.
    public static func uvSphere(radius: Double = 0.5, rings: Int = 6,
                                segments: Int = 8) throws -> HalfEdgeMesh {
        try requirePositive(radius, "radius")
        try require(rings >= 2, "rings must be ≥ 2")
        try require(segments >= 3, "segments must be ≥ 3")

        var mesh = HalfEdgeMesh()
        let top = mesh.addVertex(SIMD3(0, radius, 0))
        var latitudes: [[VertexID]] = []
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            latitudes.append(ring(&mesh, radius: radius * sin(phi),
                                  y: radius * cos(phi), count: segments))
        }
        let bottom = mesh.addVertex(SIMD3(0, -radius, 0))

        for i in 0..<segments {                       // top fan (outward)
            let j = (i + 1) % segments
            mesh.addFace([top, latitudes[0][j], latitudes[0][i]])
        }
        for r in 0..<(latitudes.count - 1) {          // interior quads
            addTubeQuads(&mesh, lower: latitudes[r + 1], upper: latitudes[r])
        }
        for i in 0..<segments {                       // bottom fan (outward)
            let j = (i + 1) % segments
            mesh.addFace([bottom, latitudes.last![i], latitudes.last![j]])
        }
        return mesh
    }

    // MARK: - Shared helpers

    /// Circle of `count` vertices at height `y`, θ increasing +X → +Z.
    private static func ring(_ mesh: inout HalfEdgeMesh, radius: Double, y: Double,
                             count: Int) -> [VertexID] {
        (0..<count).map { i in
            let theta = 2 * Double.pi * Double(i) / Double(count)
            return mesh.addVertex(SIMD3(radius * cos(theta), y, radius * sin(theta)))
        }
    }

    /// Quads between two same-count rings, `lower` below `upper`, wound
    /// outward for the +X→+Z θ convention: [lower_i, upper_i, upper_j, lower_j].
    private static func addTubeQuads(_ mesh: inout HalfEdgeMesh,
                                     lower: [VertexID], upper: [VertexID]) {
        let n = lower.count
        for i in 0..<n {
            let j = (i + 1) % n
            mesh.addFace([lower[i], upper[i], upper[j], lower[j]])
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MeshOpError.preconditionFailed(message) }
    }

    private static func requirePositive(_ value: Double, _ name: String) throws {
        try require(value > 0, "\(name) must be > 0")
    }
}
