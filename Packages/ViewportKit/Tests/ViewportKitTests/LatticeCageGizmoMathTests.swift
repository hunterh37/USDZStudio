import Testing
import Foundation
import MeshKit
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

/// Lattice cage gizmo math (specs/mesh-editing.md §Lattice deformer). Pure
/// hit-test / wireframe / free-drag math, hand-constructed rays.
@Suite("Lattice cage gizmo math")
struct LatticeCageGizmoMathTests {

    /// Unit-cube control points for a 2×2×2 cage (row-major i + 2j + 4k).
    private let cps: [SIMD3<Double>] = [
        SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(1,1,0),
        SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(0,1,1), SIMD3(1,1,1)]

    // MARK: wireframe edges

    @Test("2×2×2 grid has the 12 cube edges")
    func edges222() {
        let e = LatticeCageGizmoMath.edges(for: .default)
        #expect(e.count == 12)
        // Structural edges: 12 = 3 axes × 4 parallel edges.
        let norm = Set(e.map { $0.0 < $0.1 ? [$0.0, $0.1] : [$0.1, $0.0] })
        #expect(norm.count == 12)                       // no duplicates
        #expect(norm.contains([0, 1]))                  // +i edge
        #expect(norm.contains([0, 2]))                  // +j edge
        #expect(norm.contains([0, 4]))                  // +k edge
    }

    @Test("edge count matches the closed form for a general grid")
    func edgeCountGeneral() {
        // #edges = (l-1)mn + l(m-1)n + lm(n-1).
        let r = LatticeCage.Resolution(l: 3, m: 2, n: 4)
        let expected = (r.l - 1) * r.m * r.n + r.l * (r.m - 1) * r.n + r.l * r.m * (r.n - 1)
        #expect(LatticeCageGizmoMath.edges(for: r).count == expected)
    }

    // MARK: hit-testing

    @Test("ray through a control point grabs that handle")
    func hitNearestHandle() {
        // Irregular direction through exactly the (1,1,1) corner (index 7);
        // asymmetric so it grazes no other corner (cube symmetry means any
        // axis- or diagonal-aligned ray would hit two corners at once).
        let raw = SIMD3<Double>(0.5, 1.5, -5)
        let dir = raw / (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
        let ray = Ray(origin: SIMD3(1, 1, 1) - dir * 5, direction: dir)
        #expect(LatticeCageGizmoMath.hitHandle(ray: ray, controlPoints: cps, length: 1.0) == 7)
    }

    @Test("ray far from every handle misses")
    func hitMiss() {
        let ray = Ray(origin: SIMD3(9, 9, 5), direction: SIMD3(0, 0, -1))
        #expect(LatticeCageGizmoMath.hitHandle(ray: ray, controlPoints: cps, length: 1.0) == nil)
    }

    @Test("a nearer handle later in the list replaces the earlier best")
    func hitNearerReplaces() {
        // Index 0 is grazed (0.1 away); index 1 is dead-on the ray → wins.
        let pts = [SIMD3<Double>(0.1, 0, 0), SIMD3(0, 0, 0)]
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(LatticeCageGizmoMath.hitHandle(ray: ray, controlPoints: pts, length: 1.0) == 1)
    }

    @Test("degenerate handle length never grabs")
    func hitZeroLength() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(LatticeCageGizmoMath.hitHandle(ray: ray, controlPoints: cps, length: 0) == nil)
    }

    // MARK: free-drag plane math

    @Test("planeDelta measures translation in the camera-facing plane")
    func planeDelta() {
        let point = SIMD3<Double>(0, 0, 0)
        let normal = SIMD3<Double>(0, 0, 1)                 // plane z = 0
        let start = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))     // hits (0,0,0)
        let current = Ray(origin: SIMD3(0.5, 0.3, 5), direction: SIMD3(0, 0, -1)) // hits (0.5,0.3,0)
        let delta = LatticeCageGizmoMath.planeDelta(startRay: start, currentRay: current,
                                                    point: point, normal: normal)
        let d = try! #require(delta)
        #expect(abs(d.x - 0.5) < 1e-9)
        #expect(abs(d.y - 0.3) < 1e-9)
        #expect(abs(d.z) < 1e-9)
    }

    @Test("planeDelta returns nil when a ray is parallel to the plane")
    func planeDeltaParallel() {
        let point = SIMD3<Double>.zero
        let normal = SIMD3<Double>(0, 0, 1)
        let parallel = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(1, 0, 0)) // parallel to z=0
        let ok = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(LatticeCageGizmoMath.planeDelta(startRay: parallel, currentRay: ok,
                                                point: point, normal: normal) == nil)
        #expect(LatticeCageGizmoMath.planeDelta(startRay: ok, currentRay: parallel,
                                                point: point, normal: normal) == nil)
    }

    // MARK: descriptor + drag phase value semantics

    @Test("descriptor and drag phase are equatable values")
    func valueSemantics() {
        let a = LatticeCageGizmoDescriptor(controlPoints: cps, resolution: .default,
                                           selected: [7], revision: 1)
        let b = LatticeCageGizmoDescriptor(controlPoints: cps, resolution: .default,
                                           selected: [7], revision: 1)
        #expect(a == b)
        // Default selected/revision arguments.
        let bare = LatticeCageGizmoDescriptor(controlPoints: cps, resolution: .default)
        #expect(bare.selected.isEmpty)
        #expect(bare.revision == 0)
        #expect(LatticeCageGizmoDragPhase.began(handle: 3) == .began(handle: 3))
        #expect(LatticeCageGizmoDragPhase.changed(handle: 3, worldDelta: SIMD3(1, 0, 0))
                != .ended)
    }
}
