import Testing
import Foundation
@testable import MeshKit

/// #170: generated meshes carried no `primvars:st`, so every `MaterialSpec`
/// texture map was unrenderable. These cover the unwrapper itself plus the
/// invariant that matters downstream — *every* primitive ships a complete,
/// exportable UV channel, and topology ops can't silently discard it.
@Suite("MeshUV")
struct MeshUVTests {

    // MARK: - Every primitive is unwrapped

    @Test func everyPrimitiveShipsCompleteUVs() throws {
        let meshes: [(String, HalfEdgeMesh)] = [
            ("plane", try Primitives.plane(width: 2, depth: 3, segmentsX: 2, segmentsZ: 3)),
            ("box", try Primitives.box(width: 1, height: 2, depth: 3, segments: SIMD3(2, 2, 2))),
            ("cylinder", try Primitives.cylinder(radius: 0.5, height: 2, radialSegments: 12,
                                                 heightSegments: 3)),
            ("uncapped cylinder", try Primitives.cylinder(radialSegments: 8, capped: false)),
            ("cone", try Primitives.cone(radius: 1, height: 2, radialSegments: 10)),
            ("sphere", try Primitives.uvSphere(radius: 1, rings: 6, segments: 10)),
        ]
        for (name, mesh) in meshes {
            #expect(MeshUV.isFullyUnwrapped(mesh), "\(name) is missing UVs")
            // And the channel actually survives export: `flat` drops it unless
            // every face has UVs parallel to its loop.
            let flat = MeshIO.flat(from: mesh)
            #expect(flat.faceVaryingUVs.count == flat.faceVertexIndices.count,
                    "\(name) UV channel was dropped on export")
        }
    }

    /// UVs must stay inside a sane range. The seam repair deliberately lifts one
    /// side past 1, so the upper bound is 2 rather than 1 — but nothing should
    /// wander far outside the unit square, which would tile the texture
    /// unpredictably.
    @Test func uvsStayInASaneRange() throws {
        let mesh = try Primitives.uvSphere(radius: 1, rings: 6, segments: 10)
        let flat = MeshIO.flat(from: mesh)
        for uv in flat.faceVaryingUVs {
            #expect(uv.x >= -0.001 && uv.x <= 2.001)
            #expect(uv.y >= -0.001 && uv.y <= 1.001)
        }
    }

    /// A box's six sides must each cover the unit square rather than collapsing
    /// to a line — the failure mode of projecting every face onto the same two
    /// axes.
    @Test func boxSidesEachSpanTheUnitSquare() throws {
        let mesh = try Primitives.box(width: 2, height: 2, depth: 2)
        #expect(mesh.faceCount == 6)
        for face in mesh.faceOrder {
            let uvs = try #require(mesh.faceCornerUVs[face])
            let uSpan = uvs.map(\.x).max()! - uvs.map(\.x).min()!
            let vSpan = uvs.map(\.y).max()! - uvs.map(\.y).min()!
            #expect(uSpan > 0.9, "face collapsed in u")
            #expect(vSpan > 0.9, "face collapsed in v")
        }
    }

    /// A cylinder cap is a disc: every one of its corners sits at the same
    /// height, so a cylindrical wrap would smear it into a single line of
    /// texels. It gets a planar disc projection instead.
    @Test func cylinderCapsGetADiscProjectionNotALine() throws {
        let mesh = try Primitives.cylinder(radius: 0.5, height: 2, radialSegments: 12)
        // Caps are the last two faces (bottom then top).
        for face in mesh.faceOrder.suffix(2) {
            let uvs = try #require(mesh.faceCornerUVs[face])
            let vSpan = uvs.map(\.y).max()! - uvs.map(\.y).min()!
            #expect(vSpan > 0.5, "cap collapsed to a line in v")
        }
    }

    // MARK: - Ops must not destroy the channel

    /// The all-or-nothing export was the sharp edge: `flat` emits UVs only when
    /// every face has them, so a single op-minted face used to discard the whole
    /// set. `flatTextured` fills the gaps instead.
    @Test func opMintedFacesDoNotDiscardTheWholeChannel() throws {
        var mesh = try Primitives.box(width: 1, height: 1, depth: 1)
        #expect(MeshIO.flat(from: mesh).faceVaryingUVs.isEmpty == false)

        // Simulate what a topology op does: replace a face loop, which
        // invalidates that face's per-corner UVs.
        let face = mesh.faceOrder[0]
        let loop = try #require(mesh.faceLoops[face])
        mesh.replaceLoop(loop, for: face)
        #expect(mesh.faceCornerUVs[face] == nil)

        // Plain `flat` now drops everything — the #170 failure.
        #expect(MeshIO.flat(from: mesh).faceVaryingUVs.isEmpty)
        // `flatTextured` repairs only the hole.
        let repaired = MeshIO.flatTextured(from: mesh)
        #expect(repaired.faceVaryingUVs.count == repaired.faceVertexIndices.count)
    }

    /// The honest boundary of the #170 fix, worth pinning explicitly: ops that
    /// already carry UVs through (solidify/mirror/decimate) keep the *original*
    /// values, and the fill patches only what the op left bare. The fill is a
    /// safety net, not a silent full re-unwrap that would discard whatever UVs
    /// an op took care to preserve.
    @Test func fillPatchesOnlyOpMintedFacesAndKeepsPreservedOnes() throws {
        // An open surface, so solidify has a boundary to bridge.
        let plane = try Primitives.plane(width: 2, depth: 2, segmentsX: 2, segmentsZ: 2)
        #expect(plane.faceCornerUVs.count == 4)

        // Solidify preserves UVs on the faces it shells and mints new rim faces
        // without them — a real mixed case rather than a synthetic one.
        let solid = try Solidify.apply(
            plane, selection: .faces(Set(plane.faceOrder)),
            params: .init(thickness: 0.1)).mesh
        let preserved = solid.faceOrder.filter { solid.faceCornerUVs[$0] != nil }
        #expect(!preserved.isEmpty, "solidify should carry some UVs through")

        // After the fill, every face has UVs and the carried-through ones are
        // byte-identical to what the op produced.
        var filled = solid
        MeshUV.fillMissing(&filled)
        #expect(MeshUV.isFullyUnwrapped(filled))
        for face in preserved {
            #expect(filled.faceCornerUVs[face] == solid.faceCornerUVs[face],
                    "fill must not rewrite a UV the op preserved")
        }
        // And the whole channel now exports.
        #expect(MeshIO.flat(from: filled).faceVaryingUVs.isEmpty == false)
    }

    @Test func fillMissingLeavesExistingUVsUntouched() throws {
        var mesh = try Primitives.plane(width: 1, depth: 1)
        let face = mesh.faceOrder[0]
        let authored = [SIMD2<Double>(0.25, 0.25), SIMD2(0.75, 0.25),
                        SIMD2(0.75, 0.75), SIMD2(0.25, 0.75)]
        mesh.setFaceUVs(authored, for: face)
        MeshUV.fillMissing(&mesh)
        #expect(mesh.faceCornerUVs[face] == authored)
    }

    @Test func unwrapReplacesExistingUVs() throws {
        var mesh = try Primitives.plane(width: 1, depth: 1)
        let face = mesh.faceOrder[0]
        mesh.setFaceUVs(Array(repeating: SIMD2(0.5, 0.5), count: 4), for: face)
        MeshUV.unwrap(&mesh, using: .box)
        #expect(mesh.faceCornerUVs[face] != Array(repeating: SIMD2(0.5, 0.5), count: 4))
    }

    // MARK: - Seam repair

    /// A face straddling θ = π gets corner `u`s like [0.98, 0.02], which
    /// stretches the texture backwards across the whole map. The repair lifts
    /// the low side instead.
    @Test func seamRepairMakesStraddlingFacesContinuous() {
        let straddling = [SIMD2<Double>(0.98, 0), SIMD2(0.02, 0), SIMD2(0.02, 1)]
        let repaired = MeshUV.repairSeam(straddling)
        #expect(repaired.map(\.x) == [0.98, 1.02, 1.02])
    }

    @Test func seamRepairLeavesNormalFacesAlone() {
        let normal = [SIMD2<Double>(0.4, 0), SIMD2(0.5, 0), SIMD2(0.5, 1)]
        #expect(MeshUV.repairSeam(normal) == normal)
    }

    @Test func seamRepairHandlesDegenerateInput() {
        #expect(MeshUV.repairSeam([]).isEmpty)
        let single = [SIMD2<Double>(0.9, 0.1)]
        #expect(MeshUV.repairSeam(single) == single)
    }

    // MARK: - Guards and degenerate geometry

    @Test func emptyMeshIsNotReportedUnwrapped() {
        var mesh = HalfEdgeMesh()
        MeshUV.unwrap(&mesh, using: .box)
        // No faces means no UV channel to export, so `flat` correctly emits none.
        #expect(MeshUV.isFullyUnwrapped(mesh) == false)
    }

    /// A flat plane has zero thickness in Y; the bounds divisor must not be zero.
    @Test func degenerateAxisDoesNotProduceNonFiniteUVs() throws {
        let mesh = try Primitives.plane(width: 2, depth: 2)
        for face in mesh.faceOrder {
            for uv in mesh.faceCornerUVs[face] ?? [] {
                #expect(uv.x.isFinite)
                #expect(uv.y.isFinite)
            }
        }
    }

    @Test func setFaceUVsRejectsAMismatchedCount() throws {
        var mesh = try Primitives.plane(width: 1, depth: 1)
        let face = mesh.faceOrder[0]
        let before = mesh.faceCornerUVs[face]
        mesh.setFaceUVs([SIMD2(0, 0)], for: face)   // 1 UV for a 4-corner face
        #expect(mesh.faceCornerUVs[face] == before)
    }

    @Test func setFaceUVsIgnoresAnUnknownFace() {
        var mesh = HalfEdgeMesh()
        mesh.setFaceUVs([SIMD2(0, 0)], for: FaceID(999))
        #expect(mesh.faceCornerUVs.isEmpty)
    }

    /// A point at the sphere's exact centre has no direction to derive a
    /// longitude from; it must fall back rather than produce NaN.
    @Test func sphericalUVAtOriginFallsBackToCentre() {
        #expect(MeshUV.sphericalUV(SIMD3(0, 0, 0)) == SIMD2(0.5, 0.5))
    }

    /// Newell's method, not a first-three-corners cross product: a concave
    /// polygon's normal must still point the right way.
    @Test func normalUsesNewellForConcavePolygons() {
        // An L-shaped face in the XZ plane, wound so the normal is +Y.
        let corners: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 2), SIMD3(1, 0, 2),
            SIMD3(1, 0, 1), SIMD3(2, 0, 1), SIMD3(2, 0, 0),
        ]
        let n = MeshUV.normal(of: corners)
        #expect(n.y > 0)
        #expect(abs(n.x) < 1e-9)
        #expect(abs(n.z) < 1e-9)
    }
}
