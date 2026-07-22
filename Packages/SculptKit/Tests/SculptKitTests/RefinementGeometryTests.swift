import Foundation
import MeshKit
import simd
import SculptKit
import Testing

/// Sculpt-accuracy P4 (#85): the geometry resolver for the expressiveness ops —
/// real MeshKit geometry and deterministic selections. `RefinementGeometry`
/// lives in SculptKit next to `MeshRefinement` and is shared by both executors
/// (the AgentMCP tool pipeline and the in-app `SculptBuildRunner`); the
/// executor wiring is covered in AgentMCP's `SculptRefinementGeometryTests`,
/// the declarative coding/validation side in `RefinementExpressivenessTests`.
@Suite struct RefinementGeometryTests {

    static func extents(_ mesh: HalfEdgeMesh, where filter: (SIMD3<Double>) -> Bool = { _ in true })
        -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for p in mesh.positions.values where filter(p) {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    // MARK: - Taper (the wedge op)

    @Test func taperNarrowsTheHighEndOnEveryAxis() throws {
        for axis in RefinementAxis.allCases {
            let box = try Primitives.box(width: 2, height: 2, depth: 2, segments: SIMD3(2, 2, 2))
            let tapered = try RefinementGeometry.taper(box, axis: axis, scale: 0.4)

            func component(_ p: SIMD3<Double>) -> Double {
                switch axis {
                case .x: return p.x
                case .y: return p.y
                case .z: return p.z
                }
            }
            func crossWidth(_ pick: (Double) -> Bool) -> Double {
                let e = Self.extents(tapered) { pick(component($0)) }
                let span = e.max - e.min
                switch axis {
                case .x: return max(span.y, span.z)
                case .y: return max(span.x, span.z)
                case .z: return max(span.x, span.y)
                }
            }
            let low = crossWidth { $0 < -0.9 }
            let high = crossWidth { $0 > 0.9 }
            // 1× cross-section at the low end, ~0.4× at the high end: a wedge.
            #expect(high < low * 0.5, "axis \(axis): high \(high) not tapered vs low \(low)")
            #expect(abs(low - 2) < 0.05, "axis \(axis): low end must stay at rest size")
        }
    }

    /// A flat (zero-thickness) mesh exercises the degenerate-extent padding:
    /// the cage keeps a positive rest volume and the taper still applies.
    @Test func taperHandlesFlatGeometry() throws {
        let plane = try Primitives.plane(width: 2, depth: 2, segmentsX: 2, segmentsZ: 2)
        let tapered = try RefinementGeometry.taper(plane, axis: .z, scale: 0.2)
        let near = Self.extents(tapered) { $0.z > 0.9 }
        let far = Self.extents(tapered) { $0.z < -0.9 }
        #expect((near.max.x - near.min.x) < (far.max.x - far.min.x) * 0.5)
    }

    // MARK: - Bevel (chamfer sharp edges)

    @Test func bevelChamfersSharpEdgesDeterministically() throws {
        let box = try Primitives.box()
        let beveled = try RefinementGeometry.bevel(box, width: 0.05, angleDegrees: 30)
        // Chamfering adds geometry.
        #expect(beveled.faceCount > box.faceCount)
        #expect(beveled.vertexCount > box.vertexCount)
        // Deterministic: same input, same topology, byte-for-byte positions.
        let again = try RefinementGeometry.bevel(box, width: 0.05, angleDegrees: 30)
        #expect(again.topologyHash == beveled.topologyHash)
        #expect(again.positions == beveled.positions)
    }

    @Test func bevelWithNoSharpEdgesFailsLoudly() throws {
        // A segmented flat plane has only coplanar interior edges (dihedral 0)
        // and boundary edges (one face) — nothing to chamfer.
        let plane = try Primitives.plane(width: 1, depth: 1, segmentsX: 3, segmentsZ: 3)
        #expect(throws: MeshOpError.self) {
            _ = try RefinementGeometry.bevel(plane, width: 0.02, angleDegrees: 30)
        }
    }

    // MARK: - Directional extrude

    @Test func extrudePullsFacingRegionAndRecessesOnNegative() throws {
        let box = try Primitives.box()
        let before = Self.extents(box)

        let pulled = try RefinementGeometry.extrude(box, direction: .posY, distance: 0.3)
        let after = Self.extents(pulled)
        #expect(abs((after.max.y - before.max.y) - 0.3) < 1e-9)
        #expect(pulled.faceCount > box.faceCount)   // extrusion authors side walls

        // Negative distance recesses the region instead.
        let recessed = try RefinementGeometry.extrude(box, direction: .posY, distance: -0.2)
        let sunk = Self.extents(recessed)
        #expect(sunk.max.y < before.max.y + 1e-9)
    }

    @Test func extrudeWithNoFacingFacesFailsLoudly() throws {
        // A ground plane faces ±Y only; asking for +X facing faces is an error.
        let plane = try Primitives.plane()
        #expect(throws: MeshOpError.self) {
            _ = try RefinementGeometry.extrude(plane, direction: .posX, distance: 0.1)
        }
    }
}
