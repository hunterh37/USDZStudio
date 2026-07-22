import Testing
import Foundation
@testable import MeshKit

/// Lattice / FFD cage deformer (specs/mesh-editing.md §Lattice deformer;
/// research/topics/lattice-deformer). Covers the FFD math invariants — rest
/// identity, affine reproduction, partition of unity, outside-clamp,
/// extrapolation — plus the `LatticeDeform` op's contract.
@Suite("LatticeDeform")
struct LatticeDeformTests {

    // MARK: Fixtures

    /// A jittered point cloud inside the unit cube — enough spread to exercise
    /// interior cells at higher resolutions.
    private func samplePoints() -> [SIMD3<Double>] {
        var pts: [SIMD3<Double>] = []
        var seed: UInt64 = 0xA11CE
        func rng() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<60 { pts.append(SIMD3(rng(), rng(), rng())) }
        // Pin the exact corners/center so boundary behavior is always sampled.
        pts += [.zero, SIMD3(1, 1, 1), SIMD3(0.5, 0.5, 0.5)]
        return pts
    }

    private func unitCage(_ interp: LatticeCage.Interpolation,
                          resolution: LatticeCage.Resolution = .default,
                          affectOutside: Bool = false) -> LatticeCage {
        LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                           resolution: resolution,
                           interpolation: interp,
                           affectOutside: affectOutside)
    }

    private func maxDelta(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        zip(a, b).map { simd_length($0 - $1) }.max() ?? 0
    }

    // MARK: Rest identity (invariant 2)

    @Test("rest cage reproduces its input — trilinear (exact)")
    func restIdentityTrilinear() throws {
        for res in [LatticeCage.Resolution.default, .init(l: 4, m: 3, n: 2)] {
            let cage = unitCage(.trilinear, resolution: res)
            let pts = samplePoints()
            let out = cage.deform(try cage.bind(points: pts))
            #expect(maxDelta(out, pts) < 1e-12)
        }
    }

    @Test("rest cage reproduces its input — cubic B-spline (linear precision at borders)")
    func restIdentityCubic() throws {
        for res in [LatticeCage.Resolution.default, .init(l: 4, m: 3, n: 5)] {
            let cage = unitCage(.cubicBSpline, resolution: res)
            let pts = samplePoints()
            let out = cage.deform(try cage.bind(points: pts))
            // Extrapolated phantom nodes keep affine reproduction exact to fp noise.
            #expect(maxDelta(out, pts) < 1e-9)
        }
    }

    // MARK: Affine reproduction (invariant 3)

    @Test("2×2×2 cage reproduces an affine transform exactly")
    func affineReproduction() throws {
        var cage = unitCage(.trilinear)
        let pts = samplePoints()
        let binding = try cage.bind(points: pts)

        // Arbitrary affine: shear + non-uniform scale + translate.
        func affine(_ p: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(2 * p.x + 0.3 * p.y - 5,
                  0.5 * p.y + 0.1 * p.z + 2,
                  1.5 * p.z - 0.2 * p.x + 1)
        }
        cage.controlPoints = cage.controlPoints.map(affine)

        let out = cage.deform(binding)
        let expected = pts.map(affine)
        #expect(maxDelta(out, expected) < 1e-9)
    }

    // MARK: Partition of unity (invariant 4)

    @Test("basis weights sum to 1 for both interpolations")
    func partitionOfUnity() {
        for interp in LatticeCage.Interpolation.allCases {
            for count in [2, 3, 5, 8] {
                for c in stride(from: -0.4, through: 1.4, by: 0.1) {
                    let s = FFDBasis.sample(c, count: count, interpolation: interp)
                    #expect(abs(s.weights.reduce(0, +) - 1) < 1e-12)
                }
            }
        }
    }

    // MARK: Actual deformation

    @Test("moving a control point deforms nearby geometry")
    func deformationMoves() throws {
        let cage = unitCage(.trilinear, resolution: .init(l: 3, m: 3, n: 3))
        let pts = [SIMD3(0.5, 0.5, 0.5)]
        let binding = try cage.bind(points: pts)
        var moved = cage
        // Nudge the center control point (i=j=k=1 of a 3³ grid) up in Y.
        moved.controlPoints[1 + 3 * (1 + 3 * 1)] += SIMD3(0, 0.5, 0)
        let out = moved.deform(binding)
        #expect(out[0].y > 0.5 + 1e-6)
        #expect(abs(out[0].x - 0.5) < 1e-9)
    }

    // MARK: affectOutside

    @Test("affectOutside=false leaves exterior geometry in place")
    func outsideClampLeavesInPlace() throws {
        var cage = unitCage(.trilinear, affectOutside: false)
        let inside = SIMD3(0.5, 0.5, 0.5)
        let outside = SIMD3(2.0, 0.5, 0.5)   // s = 2 → outside on +x
        let binding = try cage.bind(points: [inside, outside])
        cage.controlPoints = cage.controlPoints.map { $0 * 3 }   // scale the whole cage
        let out = cage.deform(binding)
        #expect(out[1] == outside)              // exterior untouched
        #expect(simd_length(out[0] - inside) > 1e-6)  // interior moved
    }

    @Test("affectOutside=true extrapolates exterior geometry on every face")
    func outsideExtrapolates() throws {
        var cage = unitCage(.cubicBSpline, affectOutside: true)
        // One point just past each of the six faces exercises all extrapolation
        // branches of controlPoint(_:_:_:).
        let outs = [SIMD3(-0.3, 0.5, 0.5), SIMD3(1.3, 0.5, 0.5),
                    SIMD3(0.5, -0.3, 0.5), SIMD3(0.5, 1.3, 0.5),
                    SIMD3(0.5, 0.5, -0.3), SIMD3(0.5, 0.5, 1.3)]
        let binding = try cage.bind(points: outs)
        cage.controlPoints = cage.controlPoints.map { $0 + SIMD3(0, 0, 10) }  // rigid shift +z
        let out = cage.deform(binding)
        // A rigid translation of every control point must translate all geometry,
        // inside or out, by the same vector.
        for (o, e) in zip(out, outs) { #expect(simd_length(o - (e + SIMD3(0, 0, 10))) < 1e-9) }
    }

    // MARK: localCoordinate

    @Test("localCoordinate maps origin/center/far corner to 0 / 0.5 / 1")
    func localCoordinate() {
        let cage = unitCage(.trilinear)
        #expect(simd_length(cage.localCoordinate(of: .zero)) < 1e-12)
        #expect(simd_length(cage.localCoordinate(of: SIMD3(0.5, 0.5, 0.5)) - SIMD3(0.5, 0.5, 0.5)) < 1e-12)
        #expect(simd_length(cage.localCoordinate(of: SIMD3(1, 1, 1)) - SIMD3(1, 1, 1)) < 1e-12)
    }

    // MARK: Validation

    @Test("validate rejects degenerate configurations")
    func validation() {
        // resolution < 2
        #expect(throws: MeshOpError.self) {
            try LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                                   resolution: .init(l: 1, m: 2, n: 2)).validate()
        }
        // resolution > max
        #expect(throws: MeshOpError.self) {
            try LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                                   resolution: .init(l: 9, m: 2, n: 2)).validate()
        }
        // control-point count mismatch
        var bad = unitCage(.trilinear)
        bad.controlPoints.removeLast()
        #expect(throws: MeshOpError.self) { try bad.validate() }
        // degenerate (flat) frame
        let flat = LatticeCage(origin: .zero, edgeS: SIMD3(1, 0, 0),
                               edgeT: SIMD3(2, 0, 0),   // parallel to S → zero volume
                               edgeU: SIMD3(0, 0, 1))
        #expect(throws: MeshOpError.self) { try flat.validate() }
        // bind surfaces the same failure
        #expect(throws: MeshOpError.self) { _ = try flat.bind(points: [.zero]) }
        // a valid cage passes
        #expect(throws: Never.self) { try unitCage(.cubicBSpline).validate() }
    }

    @Test("explicit-controlPoints initializer preserves its fields")
    func explicitControlPointsInit() {
        let cps = [SIMD3<Double>(0, 0, 0), SIMD3(1, 0, 0),
                   SIMD3(0, 1, 0), SIMD3(1, 1, 0),
                   SIMD3(0, 0, 1), SIMD3(1, 0, 1),
                   SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
        let cage = LatticeCage(origin: .zero,
                               edgeS: SIMD3(1, 0, 0), edgeT: SIMD3(0, 1, 0), edgeU: SIMD3(0, 0, 1),
                               resolution: .default, interpolation: .cubicBSpline,
                               affectOutside: true, controlPoints: cps)
        #expect(cage.controlPoints == cps)
        #expect(cage.interpolation == .cubicBSpline)
        #expect(cage.affectOutside)
    }

    @Test("restGrid tolerates single-node axes (defensive denominator guard)")
    func restGridSingleNodeAxis() {
        // m == 1 and n == 1 exercise the `count > 1 ? … : 0` else branches; the
        // resulting cage is invalid (validate rejects it) but must not divide by 0.
        let cage = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                                      resolution: .init(l: 2, m: 1, n: 1))
        #expect(cage.controlPoints.count == 2)
        #expect(throws: MeshOpError.self) { try cage.validate() }
    }

    // MARK: Op contract

    /// A unit cube mesh (8 verts, 6 quads) for op-level tests.
    private func cubeMesh() throws -> HalfEdgeMesh {
        let flat = FlatMesh(
            points: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0),
                     SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)],
            faceVertexCounts: [4, 4, 4, 4, 4, 4],
            faceVertexIndices: [0,3,2,1,  4,5,6,7,  0,1,5,4,  1,2,6,5,  2,3,7,6,  3,0,4,7])
        return try MeshIO.mesh(from: flat)
    }

    @Test("LatticeDeform bakes positions, preserves topology, holds invariants")
    func opDeforms() throws {
        let mesh = try cubeMesh()
        var cage = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                                      resolution: .init(l: 2, m: 3, n: 2),
                                      interpolation: .trilinear)
        // Shear in X proportional to Y — moves the top face corners, not just
        // interior nodes, so the baked cube vertices genuinely change.
        for i in cage.controlPoints.indices {
            cage.controlPoints[i].x += 0.5 * cage.controlPoints[i].y
        }
        let result = try LatticeDeform.apply(mesh, selection: .faces([]),
                                             params: .init(cage: cage))
        #expect(result.delta == TopologyDelta(vertices: 0, edges: 0, faces: 0))
        #expect(result.mesh.vertexCount == mesh.vertexCount)
        #expect(result.mesh.faceCount == mesh.faceCount)
        #expect(MeshInvariants.violations(in: result.mesh).isEmpty)
        // Something actually moved.
        #expect(result.mesh.topologyHash != mesh.topologyHash)
    }

    @Test("LatticeDeform with a rest cage is a no-op (bit-stable positions)")
    func opRestIsNoOp() throws {
        let mesh = try cubeMesh()
        let cage = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1),
                                      interpolation: .trilinear)
        let result = try LatticeDeform.apply(mesh, selection: .faces([]),
                                             params: .init(cage: cage))
        for v in mesh.vertexOrder {
            #expect(simd_length(result.mesh.positions[v]! - mesh.positions[v]!) < 1e-12)
        }
    }

    @Test("LatticeDeform rejects an invalid cage")
    func opRejectsInvalidCage() throws {
        let mesh = try cubeMesh()
        var bad = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1))
        bad.controlPoints.removeLast()
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeform.apply(mesh, selection: .faces([]), params: .init(cage: bad))
        }
    }

    @Test("LatticeDeform rejects a non-finite deformation")
    func opRejectsNonFinite() throws {
        let mesh = try cubeMesh()
        var cage = LatticeCage.fitted(min: .zero, max: SIMD3(1, 1, 1))
        cage.controlPoints[0] = SIMD3(.nan, 0, 0)
        #expect(throws: MeshOpError.self) {
            _ = try LatticeDeform.apply(mesh, selection: .faces([]), params: .init(cage: cage))
        }
    }
}
