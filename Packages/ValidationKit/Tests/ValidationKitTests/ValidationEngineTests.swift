import Testing
import USDCore
@testable import ValidationKit

// Builders --------------------------------------------------------------------

private func mesh(
    _ name: String,
    points: [Double]? = [0, 0, 0, 1, 0, 0, 0, 1, 0],
    counts: [Int]? = [3],
    indices: [Int]? = [0, 1, 2],
    normals: Bool = true
) -> Prim {
    var attrs: [Attribute] = []
    if let points { attrs.append(Attribute(name: "points", value: .doubleArray(points))) }
    if let counts { attrs.append(Attribute(name: "faceVertexCounts", value: .intArray(counts))) }
    if let indices { attrs.append(Attribute(name: "faceVertexIndices", value: .intArray(indices))) }
    if normals, points != nil {
        attrs.append(Attribute(name: "normals", value: .doubleArray(Array(repeating: 0, count: points!.count))))
    }
    return Prim(path: PrimPath("/\(name)")!, typeName: "Mesh", attributes: attrs)
}

private func stage(
    metersPerUnit: Double = 1,
    upAxis: UpAxis = .y,
    defaultPrim: String? = "Root",
    prims: [Prim] = []
) -> StageSnapshot {
    StageSnapshot(
        metadata: StageMetadata(upAxis: upAxis, metersPerUnit: metersPerUnit, defaultPrim: defaultPrim),
        rootPrims: prims)
}

// Individual rules ------------------------------------------------------------

@Suite("Stage rules")
struct StageRuleTests {
    @Test func upAxisFlagsZUp() {
        #expect(UpAxisRule().evaluate(stage: stage(upAxis: .z)).count == 1)
        #expect(UpAxisRule().evaluate(stage: stage(upAxis: .y)).isEmpty)
    }

    @Test func defaultPrimMissingIsWarning() {
        let diag = DefaultPrimRule().evaluate(stage: stage(defaultPrim: nil))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .warning)
    }

    @Test func defaultPrimDanglingIsError() {
        let root = Prim(path: PrimPath("/Actual")!, typeName: "Xform")
        let diag = DefaultPrimRule().evaluate(stage: stage(defaultPrim: "Missing", prims: [root]))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .error)
    }

    @Test func defaultPrimMatchingPasses() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform")
        #expect(DefaultPrimRule().evaluate(stage: stage(defaultPrim: "Root", prims: [root])).isEmpty)
    }
}

@Suite("Mesh topology rule")
struct MeshTopologyRuleTests {
    private let rule = MeshTopologyRule()

    @Test func validMeshPasses() {
        #expect(rule.evaluate(stage: stage(prims: [mesh("M")])).isEmpty)
    }

    @Test func countMismatchIsError() {
        let m = mesh("M", counts: [3], indices: [0, 1, 2, 0])  // sum 3 ≠ 4
        let diag = rule.evaluate(stage: stage(prims: [m]))
        #expect(diag.contains { $0.severity == .error && $0.message.contains("≠") })
        #expect(diag.allSatisfy { $0.primPath == m.path })
    }

    @Test func degenerateFaceIsError() {
        let m = mesh("M", points: [0, 0, 0, 1, 0, 0], counts: [2], indices: [0, 1])
        #expect(rule.evaluate(stage: stage(prims: [m])).contains { $0.message.contains("fewer than 3") })
    }

    @Test func outOfRangeIndexIsError() {
        let m = mesh("M", indices: [0, 1, 9])
        #expect(rule.evaluate(stage: stage(prims: [m])).contains { $0.message.contains("references vertex 9") })
    }

    @Test func meshWithoutTopologyArraysIsSkipped() {
        let m = mesh("M", counts: nil, indices: nil)
        #expect(rule.evaluate(stage: stage(prims: [m])).isEmpty)
    }
}

@Suite("Mesh presence rules")
struct MeshPresenceRuleTests {
    @Test func emptyMeshWarns() {
        let m = mesh("M", points: nil, counts: nil, indices: nil)
        #expect(EmptyMeshRule().evaluate(stage: stage(prims: [m])).count == 1)
        #expect(EmptyMeshRule().evaluate(stage: stage(prims: [mesh("Full")])).isEmpty)
    }

    @Test func missingNormalsIsInfo() {
        let m = mesh("M", normals: false)
        let diag = MissingNormalsRule().evaluate(stage: stage(prims: [m]))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .info)
        #expect(MissingNormalsRule().evaluate(stage: stage(prims: [mesh("N")])).isEmpty)
    }
}

// Engine ----------------------------------------------------------------------

@Suite("ValidationEngine")
struct ValidationEngineTests {
    @Test func cleanStageIsCompliant() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh("Cube")])
        let report = ValidationEngine.arkitProfile.validate(stage(prims: [root]))
        #expect(report.isCompliant)
        #expect(report.errorCount == 0)
    }

    @Test func errorsBlockComplianceAndSortFirst() {
        // Z-up (warning) + dangling defaultPrim (error) + broken mesh (error).
        let broken = mesh("Bad", indices: [0, 1, 42])
        let report = ValidationEngine.arkitProfile.validate(
            stage(upAxis: .z, defaultPrim: "Nope", prims: [broken]))
        #expect(!report.isCompliant)
        #expect(report.errorCount >= 2)
        #expect(report.diagnostics.first?.severity == .error)
        // Severity is non-increasing across the sorted list.
        for (a, b) in zip(report.diagnostics, report.diagnostics.dropFirst()) {
            #expect(a.severity >= b.severity)
        }
    }

    @Test func customCatalogRunsOnlyGivenRules() {
        let engine = ValidationEngine(rules: [UpAxisRule()])
        let report = engine.validate(stage(upAxis: .z, defaultPrim: nil))
        #expect(report.diagnostics.count == 1)  // DefaultPrimRule not in catalog
        #expect(report.diagnostics[0].ruleID == "stage.upAxis")
    }
}
