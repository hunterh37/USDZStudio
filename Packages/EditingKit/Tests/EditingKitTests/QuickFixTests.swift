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

    // MARK: rules without fixes

    @Test func noFixForUnfixableRules() {
        let s = InMemoryStage(StageSnapshot())
        // Topology/normals/materials need human judgement; duplicate-name is
        // handled by manual rename (its fix cannot round-trip the uniqueness
        // guard); upAxis re-orientation is an export-time concern.
        for ruleID in ["mesh.topology", "mesh.empty", "mesh.unbound", "mesh.normals",
                       "stage.upAxis", "prim.duplicateName"] {
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
}
