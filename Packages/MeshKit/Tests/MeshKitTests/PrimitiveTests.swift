import Testing
import Foundation
@testable import MeshKit

/// Every generator, across a parameter sweep, must satisfy the Primitives
/// contract: invariants (closed where applicable), outward winding, genus-0
/// Euler characteristic, closed-form counts, analytic volume, and a lossless
/// MeshIO round-trip.
@Suite("Primitives")
struct PrimitiveTests {

    // MARK: - Shared assertions

    private func assertClosedAndOutward(_ mesh: HalfEdgeMesh,
                                        expectedVolume: Double? = nil,
                                        volumeTolerance: Double = 1e-9) throws {
        #expect(MeshInvariants.violations(in: mesh, allowBoundaries: false).isEmpty)
        #expect(MeshInvariants.eulerCharacteristic(of: mesh) == 2)
        #expect(mesh.signedVolume > 0)
        if let expectedVolume {
            #expect(abs(mesh.signedVolume - expectedVolume) <= volumeTolerance,
                    "volume \(mesh.signedVolume) ≠ \(expectedVolume)")
        }
        try assertRoundTrips(mesh)
    }

    private func assertConvexNormalsPointOutward(_ mesh: HalfEdgeMesh) {
        var center = SIMD3<Double>()
        for v in mesh.vertexOrder { center += mesh.positions[v]! }
        center /= Double(mesh.vertexCount)
        for f in mesh.faceOrder {
            let outwardness = simd_dot(mesh.faceNormalArea(f), mesh.faceCentroid(f) - center)
            #expect(outwardness > 0, "face \(f.rawValue) winds inward")
        }
    }

    private func assertRoundTrips(_ mesh: HalfEdgeMesh) throws {
        let flat = MeshIO.flat(from: mesh)
        let back = try MeshIO.mesh(from: flat)
        #expect(MeshIO.flat(from: back) == flat)
    }

    // MARK: - Plane

    @Test(arguments: [(1, 1), (1, 4), (4, 1), (3, 5)])
    func planeCountsAndHealth(_ p: (sx: Int, sz: Int)) throws {
        let (sx, sz) = p
        let mesh = try Primitives.plane(width: 2, depth: 3, segmentsX: sx, segmentsZ: sz)
        #expect(mesh.vertexCount == (sx + 1) * (sz + 1))
        #expect(mesh.faceCount == sx * sz)
        #expect(mesh.edgeCount == sx * (sz + 1) + sz * (sx + 1))
        #expect(MeshInvariants.violations(in: mesh).isEmpty)
        #expect(mesh.boundaryEdges.count == 2 * (sx + sz))
        // Every face points +Y and total area is width × depth.
        var area = 0.0
        for f in mesh.faceOrder {
            let n = mesh.faceNormalArea(f)
            #expect(n.y > 0 && abs(n.x) < 1e-12 && abs(n.z) < 1e-12)
            area += mesh.faceArea(f)
        }
        #expect(abs(area - 6) < 1e-9)
        try assertRoundTrips(mesh)
    }

    @Test func planeIsCenteredAtOrigin() throws {
        let mesh = try Primitives.plane(width: 4, depth: 2, segmentsX: 2, segmentsZ: 2)
        let (lo, hi) = USDAWriter.extent(of: mesh.vertexOrder.map { mesh.positions[$0]! })
        #expect(lo == SIMD3(-2, 0, -1) && hi == SIMD3(2, 0, 1))
    }

    // MARK: - Box

    @Test(arguments: [SIMD3(1, 1, 1), SIMD3(2, 1, 1), SIMD3(2, 3, 4), SIMD3(1, 5, 1)])
    func boxCountsVolumeAndWinding(segments: SIMD3<Int>) throws {
        let (w, h, d) = (2.0, 1.0, 3.0)
        let mesh = try Primitives.box(width: w, height: h, depth: d, segments: segments)
        let (sx, sy, sz) = (segments.x, segments.y, segments.z)
        // Surface lattice: full lattice minus strict interior.
        let expectedV = (sx + 1) * (sy + 1) * (sz + 1) - max(0, sx - 1) * max(0, sy - 1) * max(0, sz - 1)
        #expect(mesh.vertexCount == expectedV)
        #expect(mesh.faceCount == 2 * (sx * sy + sy * sz + sz * sx))
        try assertClosedAndOutward(mesh, expectedVolume: w * h * d)
        assertConvexNormalsPointOutward(mesh)
    }

    @Test func unitBoxIsTheCanonicalCube() throws {
        let mesh = try Primitives.box()
        #expect(mesh.vertexCount == 8 && mesh.edgeCount == 12 && mesh.faceCount == 6)
        try assertClosedAndOutward(mesh, expectedVolume: 1)
    }

    // MARK: - Cylinder

    @Test(arguments: [(3, 1), (8, 1), (8, 3), (16, 2)])
    func cylinderCountsAndVolume(_ p: (n: Int, h: Int)) throws {
        let (n, h) = p
        let mesh = try Primitives.cylinder(radius: 1, height: 2, radialSegments: n,
                                           heightSegments: h)
        #expect(mesh.vertexCount == n * (h + 1))
        #expect(mesh.faceCount == n * h + 2)
        #expect(mesh.edgeCount == n * (h + 1) + n * h)
        // Discrete volume: prism over the inscribed n-gon.
        let polygonArea = Double(n) / 2 * sin(2 * .pi / Double(n))
        try assertClosedAndOutward(mesh, expectedVolume: polygonArea * 2, volumeTolerance: 1e-9)
        assertConvexNormalsPointOutward(mesh)
    }

    @Test func uncappedCylinderIsAnOpenTube() throws {
        let mesh = try Primitives.cylinder(radialSegments: 6, capped: false)
        #expect(MeshInvariants.violations(in: mesh).isEmpty)
        #expect(mesh.boundaryEdges.count == 12) // two open rims
        try assertRoundTrips(mesh)
    }

    // MARK: - Cone

    @Test(arguments: [3, 4, 8, 24])
    func coneCountsAndVolume(n: Int) throws {
        let mesh = try Primitives.cone(radius: 1.5, height: 2, radialSegments: n)
        #expect(mesh.vertexCount == n + 1)
        #expect(mesh.faceCount == n + 1)
        #expect(mesh.edgeCount == 2 * n)
        let baseArea = Double(n) / 2 * 1.5 * 1.5 * sin(2 * .pi / Double(n))
        try assertClosedAndOutward(mesh, expectedVolume: baseArea * 2 / 3, volumeTolerance: 1e-9)
        assertConvexNormalsPointOutward(mesh)
    }

    // MARK: - Sphere

    @Test(arguments: [(2, 3), (2, 8), (6, 8), (8, 16)])
    func sphereCountsAndHealth(_ p: (rings: Int, segments: Int)) throws {
        let (rings, segments) = p
        let mesh = try Primitives.uvSphere(radius: 1, rings: rings, segments: segments)
        #expect(mesh.vertexCount == segments * (rings - 1) + 2)
        #expect(mesh.faceCount == segments * rings)
        #expect(mesh.edgeCount == segments * (rings - 1) + segments * rings)
        try assertClosedAndOutward(mesh)
        assertConvexNormalsPointOutward(mesh)
    }

    @Test func sphereVolumeConvergesToAnalytic() throws {
        // Discrete volume approaches 4/3 π r³ from below as resolution rises.
        let coarse = try Primitives.uvSphere(radius: 1, rings: 6, segments: 8).signedVolume
        let fine = try Primitives.uvSphere(radius: 1, rings: 24, segments: 32).signedVolume
        let analytic = 4.0 / 3.0 * Double.pi
        #expect(coarse < fine && fine < analytic)
        #expect(analytic - fine < 0.05)
    }

    // MARK: - Parameter validation

    @Test func generatorsRejectBadParameters() {
        #expect(throws: MeshOpError.self) { try Primitives.plane(width: 0) }
        #expect(throws: MeshOpError.self) { try Primitives.plane(segmentsX: 0) }
        #expect(throws: MeshOpError.self) { try Primitives.box(height: -1) }
        #expect(throws: MeshOpError.self) { try Primitives.box(segments: SIMD3(1, 0, 1)) }
        #expect(throws: MeshOpError.self) { try Primitives.cylinder(radialSegments: 2) }
        #expect(throws: MeshOpError.self) { try Primitives.cylinder(heightSegments: 0) }
        #expect(throws: MeshOpError.self) { try Primitives.cone(radius: 0) }
        #expect(throws: MeshOpError.self) { try Primitives.cone(radialSegments: 2) }
        #expect(throws: MeshOpError.self) { try Primitives.uvSphere(rings: 1) }
        #expect(throws: MeshOpError.self) { try Primitives.uvSphere(segments: 2) }
    }

    // MARK: - Primitives feed the op pipeline

    @Test func extrudeOnGeneratedBoxTopStaysHealthy() throws {
        let box = try Primitives.box(width: 2, height: 1, depth: 1)
        let top = Set(box.faceOrder.filter { box.faceNormalArea($0).y > 0.5 })
        let r = try ExtrudeFaces.apply(box, selection: .faces(top),
                                       params: .init(distance: 0.5))
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        #expect(abs(r.mesh.signedVolume - 3) < 1e-9) // 2×1×1 + 2×0.5×1
    }

    @Test func bevelOnGeneratedCylinderRimStaysHealthy() throws {
        let cylinder = try Primitives.cylinder(radius: 1, height: 2, radialSegments: 8)
        // One top-rim edge (bevel v1 refuses adjacent edges by design).
        let rim = cylinder.edgeFaceMap.keys.filter {
            cylinder.positions[$0.a]!.y > 0.99 && cylinder.positions[$0.b]!.y > 0.99
        }.sorted()
        #expect(rim.count == 8)
        let r = try BevelEdges.apply(cylinder, selection: .edges([rim[0]]),
                                     params: .init(width: 0.2))
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }
}
