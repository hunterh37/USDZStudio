import Testing
import USDCore
@testable import ValidationKit

// Builders --------------------------------------------------------------------

private func mesh(
    _ name: String,
    points: [Double]? = [0, 0, 0, 1, 0, 0, 0, 1, 0],
    counts: [Int]? = [3],
    indices: [Int]? = [0, 1, 2],
    normals: Bool = true,
    subdivision: Bool = true
) -> Prim {
    var attrs: [Attribute] = []
    if let points { attrs.append(Attribute(name: "points", value: .doubleArray(points))) }
    if let counts { attrs.append(Attribute(name: "faceVertexCounts", value: .intArray(counts))) }
    if let indices { attrs.append(Attribute(name: "faceVertexIndices", value: .intArray(indices))) }
    if normals, points != nil {
        attrs.append(Attribute(name: "normals", value: .doubleArray(Array(repeating: 0, count: points!.count))))
    }
    if subdivision {
        attrs.append(Attribute(name: "subdivisionScheme", value: .token("none"), isUniform: true))
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

    @Test func missingSubdivisionSchemeIsInfo() {
        let m = mesh("M", subdivision: false)
        let diag = MissingSubdivisionSchemeRule().evaluate(stage: stage(prims: [m]))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .info)
        #expect(diag[0].message.contains("catmullClark"))
        // A mesh that authors subdivisionScheme does not fire.
        #expect(MissingSubdivisionSchemeRule().evaluate(stage: stage(prims: [mesh("N")])).isEmpty)
    }
}

@Suite("Duplicate prim name rule")
struct DuplicatePrimNameRuleTests {
    private let rule = DuplicatePrimNameRule()

    @Test func uniqueSiblingsPass() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [
            Prim(path: PrimPath("/Root/A")!), Prim(path: PrimPath("/Root/B")!),
        ])
        #expect(rule.evaluate(stage: stage(prims: [root])).isEmpty)
    }

    @Test func duplicateChildrenAreOneError() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [
            Prim(path: PrimPath("/Root/Wheel")!),
            Prim(path: PrimPath("/Root/Wheel")!),
            Prim(path: PrimPath("/Root/Wheel")!),  // three copies → still one diagnostic
        ])
        let diag = rule.evaluate(stage: stage(prims: [root]))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .error)
        #expect(diag[0].ruleID == "prim.duplicateName")
        #expect(diag[0].message.contains("'Wheel'"))
        #expect(diag[0].primPath == PrimPath("/Root/Wheel"))
    }

    @Test func duplicateRootPrimsAreCaught() {
        let diag = rule.evaluate(stage: stage(prims: [
            Prim(path: PrimPath("/Dup")!), Prim(path: PrimPath("/Dup")!),
        ]))
        #expect(diag.count == 1)
        #expect(diag[0].message.contains("the stage root"))
    }
}

@Suite("Unbound mesh rule")
struct UnboundMeshRuleTests {
    private let rule = UnboundMeshRule()

    private func boundMesh(_ name: String) -> Prim {
        var prim = mesh(name)
        prim.relationships = [Relationship(name: "material:binding", targets: [PrimPath("/Mats/M")!])]
        return prim
    }

    @Test func unboundMeshIsInfo() {
        let diag = rule.evaluate(stage: stage(prims: [mesh("M")]))
        #expect(diag.count == 1)
        #expect(diag[0].severity == .info)
        #expect(diag[0].ruleID == "mesh.unbound")
        #expect(diag[0].primPath == PrimPath("/M"))
    }

    @Test func boundMeshPasses() {
        #expect(rule.evaluate(stage: stage(prims: [boundMesh("M")])).isEmpty)
    }

    @Test func purposeSpecificBindingCounts() {
        var prim = mesh("M")
        prim.relationships = [Relationship(name: "material:binding:preview", targets: [PrimPath("/Mats/M")!])]
        #expect(rule.evaluate(stage: stage(prims: [prim])).isEmpty)
    }

    @Test func emptyBindingTargetsStillUnbound() {
        var prim = mesh("M")
        prim.relationships = [Relationship(name: "material:binding", targets: [])]
        #expect(rule.evaluate(stage: stage(prims: [prim])).count == 1)
    }

    @Test func emptyMeshIsNotFlagged() {
        // No points → EmptyMeshRule's job, not ours.
        let empty = mesh("E", points: nil, counts: nil, indices: nil)
        #expect(rule.evaluate(stage: stage(prims: [empty])).isEmpty)
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

// ComplianceChecker -----------------------------------------------------------

@Suite("ComplianceChecker")
struct ComplianceCheckerTests {
    @Test func arkitAllowsCleanStage() {
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh("Cube")])
        let result = ComplianceChecker(profile: .arkit).check(stage(prims: [root]))
        #expect(result.isExportAllowed)
        #expect(result.blockingDiagnostics.isEmpty)
        #expect(result.profileID == "arkit")
    }

    @Test func arkitBlocksOnError() {
        let broken = mesh("Bad", indices: [0, 1, 42])
        let result = ComplianceChecker(profile: .arkit).check(stage(prims: [broken]))
        #expect(!result.isExportAllowed)
        #expect(result.blockingDiagnostics.allSatisfy { $0.severity == .error })
        #expect(result.summary.contains("export blocked"))
    }

    @Test func arkitAllowsWarningsButStrictBlocks() {
        // Z-up is a warning, no errors.
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh("Cube")])
        let warnStage = stage(upAxis: .z, prims: [root])

        #expect(ComplianceChecker(profile: .arkit).check(warnStage).isExportAllowed)

        let strict = ComplianceChecker(profile: .arkitStrict).check(warnStage)
        #expect(!strict.isExportAllowed)
        #expect(strict.blockingDiagnostics.contains { $0.ruleID == "stage.upAxis" })
    }

    @Test func namedLookupIsCaseInsensitive() {
        #expect(ValidationProfile.named("ARKit")?.id == "arkit")
        #expect(ValidationProfile.named("arkit-strict")?.blockingSeverity == .warning)
        #expect(ValidationProfile.named("nope") == nil)
    }
}
