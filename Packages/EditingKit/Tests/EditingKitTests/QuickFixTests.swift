import Testing
import USDCore
import ValidationKit
@testable import EditingKit

@Suite("QuickFixRegistry")
struct QuickFixTests {

    // MARK: Helpers

    private func diagnostic(ruleID: String, in stage: any USDStageProtocol) -> Diagnostic {
        let report = ValidationEngine.arkitProfile.validate(stage)
        return report.diagnostics.first { $0.ruleID == ruleID }!
    }

    private func remainingCount(ruleID: String, in stage: any USDStageProtocol) -> Int {
        ValidationEngine.arkitProfile.validate(stage)
            .diagnostics.filter { $0.ruleID == ruleID }.count
    }

    // MARK: metersPerUnit

    @Test func scaleFixNormalizesAndClearsDiagnostic() throws {
        let root = Prim(path: PrimPath("/Model")!, typeName: "Xform")
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 100000, defaultPrim: "Model"),
            rootPrims: [root]))
        let d = diagnostic(ruleID: "stage.metersPerUnit", in: s)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        #expect(fix.ruleID == "stage.metersPerUnit")
        try fix.command.execute(on: s)

        #expect(s.metadata.metersPerUnit == 1.0)
        #expect(remainingCount(ruleID: "stage.metersPerUnit", in: s) == 0)
    }

    // MARK: defaultPrim

    @Test func defaultPrimFixWhenMissing() throws {
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(defaultPrim: nil),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform")]))
        let d = diagnostic(ruleID: "stage.defaultPrim", in: s)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        #expect(fix.title == "Set defaultPrim to 'Car'")
        try fix.command.execute(on: s)

        #expect(s.metadata.defaultPrim == "Car")
        #expect(remainingCount(ruleID: "stage.defaultPrim", in: s) == 0)
    }

    @Test func defaultPrimFixWhenNamingMissingPrim() throws {
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(defaultPrim: "Ghost"),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform")]))
        let d = diagnostic(ruleID: "stage.defaultPrim", in: s)
        #expect(d.severity == .error)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        try fix.command.execute(on: s)
        #expect(s.metadata.defaultPrim == "Car")
        #expect(remainingCount(ruleID: "stage.defaultPrim", in: s) == 0)
    }

    @Test func defaultPrimFixUndoRestores() throws {
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(defaultPrim: nil),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform")]))
        let d = diagnostic(ruleID: "stage.defaultPrim", in: s)
        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        try fix.command.execute(on: s)
        try fix.command.undo(on: s)
        #expect(s.metadata.defaultPrim == nil)
    }

    @Test func noDefaultPrimFixForEmptyStage() {
        let s = InMemoryStage(StageSnapshot(metadata: StageMetadata(defaultPrim: nil)))
        let d = Diagnostic(ruleID: "stage.defaultPrim", severity: .warning, message: "x")
        #expect(QuickFixRegistry.quickFix(for: d, in: s) == nil)
    }

    // MARK: upAxis

    @Test func upAxisFixReorientsAndClearsDiagnostic() throws {
        let root = Prim(path: PrimPath("/Model")!, typeName: "Xform")
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(upAxis: .z, defaultPrim: "Model"),
            rootPrims: [root]))
        let d = diagnostic(ruleID: "stage.upAxis", in: s)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        #expect(fix.title == "Re-orient to Y-up")
        try fix.command.execute(on: s)

        #expect(s.metadata.upAxis == .y)
        // The untransformed root gains the −90° X reorientation.
        #expect(abs(s.transform(at: PrimPath("/Model")!).rotationEulerDegrees[0] - (-90)) < 1e-6)
        #expect(remainingCount(ruleID: "stage.upAxis", in: s) == 0)
    }

    @Test func noUpAxisFixWhenAlreadyYUp() {
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(upAxis: .y),
            rootPrims: [Prim(path: PrimPath("/Model")!, typeName: "Xform")]))
        let d = Diagnostic(ruleID: "stage.upAxis", severity: .warning, message: "x")
        #expect(QuickFixRegistry.quickFix(for: d, in: s) == nil)
    }

    // MARK: rules without fixes

    @Test func noFixForUnfixableRules() {
        let s = InMemoryStage(StageSnapshot())
        // Topology/normals/materials need human judgement; duplicate-name is
        // handled by manual rename (its fix cannot round-trip the uniqueness
        // guard).
        for ruleID in ["mesh.topology", "mesh.empty", "mesh.unbound", "mesh.normals",
                       "prim.duplicateName"] {
            let d = Diagnostic(ruleID: ruleID, severity: .warning, message: "x")
            #expect(QuickFixRegistry.quickFix(for: d, in: s) == nil, "\(ruleID) should have no quick-fix")
        }
    }

    // MARK: report-level aggregation

    @Test func quickFixesForReportKeepsFixableOnlyInOrder() throws {
        // Missing defaultPrim (warning) + huge scale (warning) + an unbound mesh
        // (info, no fix). Only the two fixable ones come back.
        let mesh = Prim(
            path: PrimPath("/Body")!, typeName: "Mesh",
            attributes: [Attribute(name: "points", value: .float3Array([0, 0, 0]))])
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 100000, defaultPrim: nil),
            rootPrims: [mesh]))
        let report = ValidationEngine.arkitProfile.validate(s)
        let fixes = QuickFixRegistry.quickFixes(for: report, in: s)

        #expect(Set(fixes.map(\.fix.ruleID)) == ["stage.defaultPrim", "stage.metersPerUnit"])
        // Report ordering (most-severe / ruleID) is preserved in the fix list.
        #expect(fixes.map(\.fix.ruleID) == ["stage.defaultPrim", "stage.metersPerUnit"])

        // The drawer's real loop: fix, recompute, repeat. Because each fix
        // reflects live state, applying them this way converges (a metadata
        // fix built before another no longer clobbers it).
        var applied = 0
        while let next = QuickFixRegistry.quickFixes(
            for: ValidationEngine.arkitProfile.validate(s), in: s).first {
            try next.fix.command.execute(on: s)
            applied += 1
            #expect(applied <= 5, "quick-fix loop should converge")
            if applied > 5 { break }
        }

        // Every fixable diagnostic is cleared; the info-level unbound-mesh note
        // (no fix) is left behind.
        let after = ValidationEngine.arkitProfile.validate(s)
        #expect(!after.diagnostics.contains { $0.ruleID == "stage.metersPerUnit" })
        #expect(!after.diagnostics.contains { $0.ruleID == "stage.defaultPrim" })
        #expect(after.diagnostics.contains { $0.ruleID == "mesh.unbound" })
    }

    // MARK: - Fixtures for the mesh fixes

    /// A unit quad in the XY plane, wound so its normal is +Z. Two triangles
    /// share the diagonal, so interior vertices accumulate from both faces.
    private func quadMesh(
        path: String = "/Mesh",
        normals: [Double]? = nil
    ) -> Prim {
        var attributes: [Attribute] = [
            Attribute(name: "points", value: .float3Array([
                0, 0, 0,
                1, 0, 0,
                1, 1, 0,
                0, 1, 0,
            ])),
            Attribute(name: "faceVertexCounts", value: .intArray([3, 3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 0, 2, 3])),
        ]
        if let normals {
            attributes.append(Attribute(name: "normals", value: .float3Array(normals)))
        }
        return Prim(path: PrimPath(path)!, typeName: "Mesh", attributes: attributes)
    }

    private func emptyMesh(path: String = "/Ghost") -> Prim {
        Prim(path: PrimPath(path)!, typeName: "Mesh",
             attributes: [Attribute(name: "points", value: .float3Array([]))])
    }

    private func stage(_ prims: [Prim]) -> InMemoryStage {
        InMemoryStage(StageSnapshot(
            metadata: StageMetadata(defaultPrim: prims.first?.name),
            rootPrims: prims))
    }

    // MARK: mesh.empty

    @Test func emptyMeshFixDeletesPrimAndUndoRestoresIt() throws {
        let s = stage([quadMesh(), emptyMesh()])
        let d = diagnostic(ruleID: "mesh.empty", in: s)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        #expect(fix.title == "Delete empty mesh 'Ghost'")
        try fix.command.execute(on: s)

        #expect(s.rootPrims.map(\.name) == ["Mesh"])
        #expect(remainingCount(ruleID: "mesh.empty", in: s) == 0)

        // Reversible, and back into its original sibling slot.
        try fix.command.undo(on: s)
        #expect(s.rootPrims.map(\.name) == ["Mesh", "Ghost"])
    }

    @Test func emptyMeshFixTargetsTheDiagnosticsPrimNotTheFirstEmptyOne() throws {
        let s = stage([quadMesh(), emptyMesh(path: "/A"), emptyMesh(path: "/B")])
        let report = ValidationEngine.arkitProfile.validate(s)
        let second = try #require(
            report.diagnostics.first { $0.ruleID == "mesh.empty" && $0.primPath?.name == "B" })

        let fix = try #require(QuickFixRegistry.quickFix(for: second, in: s))
        try fix.command.execute(on: s)
        #expect(s.rootPrims.map(\.name) == ["Mesh", "A"])
    }

    @Test func emptyMeshFixIsNilWhenThePrimIsGoneOrNoLongerEmpty() throws {
        let s = stage([quadMesh()])
        // A stale diagnostic pointing at a prim that has since been deleted.
        let stale = Diagnostic(
            ruleID: "mesh.empty", severity: .warning,
            message: "gone", primPath: PrimPath("/Gone")!)
        #expect(QuickFixRegistry.quickFix(for: stale, in: s) == nil)

        // …and one pointing at a mesh that has since gained points.
        let refilled = Diagnostic(
            ruleID: "mesh.empty", severity: .warning,
            message: "not empty any more", primPath: PrimPath("/Mesh")!)
        #expect(QuickFixRegistry.quickFix(for: refilled, in: s) == nil)
    }

    @Test func emptyMeshFixIsNilWithoutAPrimPath() throws {
        let s = stage([emptyMesh()])
        let unanchored = Diagnostic(ruleID: "mesh.empty", severity: .warning, message: "no path")
        #expect(QuickFixRegistry.quickFix(for: unanchored, in: s) == nil)
    }

    @Test func emptyMeshFixIsNilForANonMeshPrim() throws {
        let xform = Prim(path: PrimPath("/Rig")!, typeName: "Xform")
        let s = stage([xform])
        let misdirected = Diagnostic(
            ruleID: "mesh.empty", severity: .warning, message: "not a mesh",
            primPath: PrimPath("/Rig")!)
        #expect(QuickFixRegistry.quickFix(for: misdirected, in: s) == nil)
    }

    // MARK: mesh.normals

    @Test func normalsFixAuthorsUnitNormalsAndClearsDiagnostic() throws {
        let s = stage([quadMesh()])
        let d = diagnostic(ruleID: "mesh.normals", in: s)

        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))
        #expect(fix.title == "Compute smooth normals for 'Mesh'")
        try fix.command.execute(on: s)

        let authored = try #require(s.prim(at: PrimPath("/Mesh")!)?.attribute(named: "normals"))
        #expect(authored.metadata["interpolation"] == "\"vertex\"")
        guard case .float3Array(let values) = authored.value else {
            Issue.record("normals should be a float3 array")
            return
        }
        // One normal per point, all +Z for a CCW quad in the XY plane.
        #expect(values.count == 12)
        for vertex in 0 ..< 4 {
            #expect(abs(values[vertex * 3]) < 1e-9)
            #expect(abs(values[vertex * 3 + 1]) < 1e-9)
            #expect(abs(values[vertex * 3 + 2] - 1.0) < 1e-9)
        }
        #expect(remainingCount(ruleID: "mesh.normals", in: s) == 0)
    }

    @Test func normalsFixUndoRemovesTheAttributeEntirely() throws {
        let s = stage([quadMesh()])
        let d = diagnostic(ruleID: "mesh.normals", in: s)
        let fix = try #require(QuickFixRegistry.quickFix(for: d, in: s))

        let before = s.prim(at: PrimPath("/Mesh")!)
        try fix.command.execute(on: s)
        try fix.command.undo(on: s)

        // The attribute did not exist before, so undo must not leave an empty
        // one behind — the prim returns to exactly its prior state.
        #expect(s.prim(at: PrimPath("/Mesh")!)?.attribute(named: "normals") == nil)
        #expect(s.prim(at: PrimPath("/Mesh")!) == before)
    }

    @Test func normalsFixIsNilWhenNormalsAlreadyExist() throws {
        let s = stage([quadMesh(normals: Array(repeating: 0, count: 12))])
        let stale = Diagnostic(
            ruleID: "mesh.normals", severity: .info, message: "stale",
            primPath: PrimPath("/Mesh")!)
        #expect(QuickFixRegistry.quickFix(for: stale, in: s) == nil)
    }

    @Test func normalsFixIsNilWithoutAPrimPathOrPrim() throws {
        let s = stage([quadMesh()])
        #expect(QuickFixRegistry.quickFix(
            for: Diagnostic(ruleID: "mesh.normals", severity: .info, message: "no path"),
            in: s) == nil)
        #expect(QuickFixRegistry.quickFix(
            for: Diagnostic(ruleID: "mesh.normals", severity: .info, message: "gone",
                            primPath: PrimPath("/Gone")!),
            in: s) == nil)
    }

    @Test func normalsFixDeclinesDegenerateTopologyRatherThanGuessing() throws {
        // Indices reference a vertex the mesh does not have: a mesh.topology
        // error. The normals fix must stand down rather than paper over it.
        let broken = Prim(path: PrimPath("/Bad")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 9])),
        ])
        let s = stage([broken])
        let d = Diagnostic(ruleID: "mesh.normals", severity: .info, message: "broken",
                           primPath: PrimPath("/Bad")!)
        #expect(QuickFixRegistry.quickFix(for: d, in: s) == nil)
    }

    // MARK: - MeshNormals geometry

    @Test func smoothNormalsAreAreaWeightedAcrossSharedVertices() throws {
        // An L-shaped pair of faces meeting at a shared edge: the shared
        // vertices blend both face normals, weighted by area.
        let prim = Prim(path: PrimPath("/L")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([
                0, 0, 0,
                1, 0, 0,
                1, 1, 0,
                0, 1, 0,
                1, 0, 1,
                1, 1, 1,
            ])),
            // Quad in XY (normal +Z) and quad in YZ (normal +X).
            Attribute(name: "faceVertexCounts", value: .intArray([4, 4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3, 1, 2, 5, 4])),
        ])
        let normals = try #require(MeshNormals.smoothVertexNormals(of: prim))
        #expect(normals.count == 18)

        func normal(_ i: Int) -> (Double, Double, Double) {
            (normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2])
        }
        // Vertex 0 touches only the XY face → pure +Z.
        let (x0, y0, z0) = normal(0)
        #expect(abs(x0) < 1e-9 && abs(y0) < 1e-9 && abs(z0 - 1) < 1e-9)
        // Vertex 1 is shared by both equal-area faces → the +X/+Z bisector.
        let (x1, y1, z1) = normal(1)
        #expect(abs(x1 - z1) < 1e-9)
        #expect(x1 > 0 && z1 > 0 && abs(y1) < 1e-9)
        // Every emitted normal is unit length.
        for v in 0 ..< 6 {
            let (x, y, z) = normal(v)
            #expect(abs((x * x + y * y + z * z).squareRoot() - 1.0) < 1e-9)
        }
    }

    @Test func smoothNormalsLeaveUntouchedVerticesAtZero() throws {
        // A 4-point mesh whose single face uses only 3 of them: the orphan
        // vertex gets a zero normal rather than a fabricated direction.
        let prim = Prim(path: PrimPath("/Orphan")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 5, 5, 5])),
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2])),
        ])
        let normals = try #require(MeshNormals.smoothVertexNormals(of: prim))
        #expect(normals[9] == 0 && normals[10] == 0 && normals[11] == 0)
    }

    @Test func smoothNormalsRejectMalformedInput() throws {
        func mesh(_ attributes: [Attribute], type: String = "Mesh") -> Prim {
            Prim(path: PrimPath("/M")!, typeName: type, attributes: attributes)
        }
        let goodPoints = Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 0, 1, 0]))
        let goodCounts = Attribute(name: "faceVertexCounts", value: .intArray([3]))
        let goodIndices = Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2]))

        // Not a mesh.
        #expect(MeshNormals.smoothVertexNormals(
            of: mesh([goodPoints, goodCounts, goodIndices], type: "Xform")) == nil)
        // No points attribute at all.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([goodCounts, goodIndices])) == nil)
        // Empty points.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([
            Attribute(name: "points", value: .float3Array([])), goodCounts, goodIndices])) == nil)
        // Points array not a multiple of 3.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1])), goodCounts, goodIndices])) == nil)
        // Missing counts / missing indices.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([goodPoints, goodIndices])) == nil)
        #expect(MeshNormals.smoothVertexNormals(of: mesh([goodPoints, goodCounts])) == nil)
        // Counts sum ≠ index count.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([
            goodPoints, Attribute(name: "faceVertexCounts", value: .intArray([4])), goodIndices])) == nil)
        // A face with fewer than 3 corners.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([
            goodPoints,
            Attribute(name: "faceVertexCounts", value: .intArray([2])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1]))])) == nil)
        // A negative index.
        #expect(MeshNormals.smoothVertexNormals(of: mesh([
            goodPoints, goodCounts,
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, -1]))])) == nil)
    }

    @Test func smoothNormalsAcceptDoubleArrayPoints() throws {
        let prim = Prim(path: PrimPath("/D")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .doubleArray([0, 0, 0, 1, 0, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2])),
        ])
        let normals = try #require(MeshNormals.smoothVertexNormals(of: prim))
        #expect(abs(normals[2] - 1.0) < 1e-9)
    }

    @Test func pointsAccessorDistinguishesAbsentFromEmpty() throws {
        #expect(MeshNormals.points(of: Prim(path: PrimPath("/N")!, typeName: "Mesh")) == nil)
        #expect(MeshNormals.points(of: Prim(path: PrimPath("/N")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([]))])) == [])
        // Wrong type reads as absent, not empty.
        #expect(MeshNormals.points(of: Prim(path: PrimPath("/N")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .int(3))])) == nil)
    }

    @Test func intArrayAccessorReturnsNilForOtherTypes() throws {
        let prim = Prim(path: PrimPath("/I")!, typeName: "Mesh", attributes: [
            Attribute(name: "counts", value: .intArray([1, 2])),
            Attribute(name: "other", value: .string("nope")),
        ])
        #expect(MeshNormals.intArray(prim, "counts") == [1, 2])
        #expect(MeshNormals.intArray(prim, "other") == nil)
        #expect(MeshNormals.intArray(prim, "absent") == nil)
    }
}
