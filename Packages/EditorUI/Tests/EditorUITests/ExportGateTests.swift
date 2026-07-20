import Testing
import USDCore
import ValidationKit
@testable import EditorUI

/// Covers the export compliance gate's policy (ROADMAP Milestone 5). The gate
/// decides *whether* an export may proceed; these tests pin that decision for
/// every stage class and profile, including the override escape hatch.
@Suite("ExportGate")
struct ExportGateTests {

    // MARK: Fixtures

    /// Clean: real-world scale, resolvable defaultPrim, no meshes to complain
    /// about.
    private func cleanStage() -> StageSnapshot {
        StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Car"),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform")])
    }

    /// Warning-only: an empty mesh trips `mesh.empty` (a warning), nothing errors.
    private func warningStage() -> StageSnapshot {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh",
                         attributes: [Attribute(name: "points", value: .float3Array([]))])
        return StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Car"),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])])
    }

    /// Erroring: defaultPrim names a prim that is not there.
    private func errorStage() -> StageSnapshot {
        StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Ghost"),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform")])
    }

    // MARK: Verdicts

    @Test func cleanStagePassesWithNoDiagnostics() {
        let decision = ExportGate.evaluate(stage: cleanStage(), profileID: "arkit")
        #expect(decision.verdict == .clean)
        #expect(decision.allowsExport)
        #expect(!decision.allowsOverride)
        #expect(decision.blockingDiagnostics.isEmpty)
        #expect(decision.advisoryDiagnostics.isEmpty)
        #expect(decision.headline == "Passes the arkit profile.")
        #expect(decision.systemImage == "checkmark.seal.fill")
    }

    @Test func warningsAreAdvisoryUnderTheDefaultProfile() {
        let decision = ExportGate.evaluate(stage: warningStage(), profileID: "arkit")
        #expect(decision.verdict == .advisory)
        #expect(decision.allowsExport)
        #expect(!decision.allowsOverride)
        #expect(decision.blockingDiagnostics.isEmpty)
        #expect(decision.advisoryDiagnostics.contains { $0.ruleID == "mesh.empty" })
        #expect(decision.headline.contains("export is allowed"))
        #expect(decision.systemImage == "info.circle.fill")
    }

    @Test func theSameWarningsBlockUnderTheStrictProfile() {
        let lax = ExportGate.evaluate(stage: warningStage(), profileID: "arkit")
        let strict = ExportGate.evaluate(stage: warningStage(), profileID: "arkit-strict")

        // Identical stage, identical diagnostics — only the threshold moved.
        #expect(lax.result.report.diagnostics == strict.result.report.diagnostics)
        #expect(strict.allowsExport == false)
        #expect(strict.allowsOverride)
        if case .blocked(let count) = strict.verdict {
            #expect(count > 0)
        } else {
            Issue.record("strict profile should block a warning stage")
        }
        #expect(strict.systemImage == "exclamationmark.triangle.fill")
    }

    @Test func errorsBlockEvenUnderTheDefaultProfile() {
        let decision = ExportGate.evaluate(stage: errorStage(), profileID: "arkit")
        #expect(decision.verdict == .blocked(count: 1))
        #expect(!decision.allowsExport)
        #expect(decision.allowsOverride)
        #expect(decision.blockingDiagnostics.first?.ruleID == "stage.defaultPrim")
        #expect(decision.headline == "1 issue blocks export.")
    }

    @Test func headlinePluralisesCorrectly() {
        // Two blocking issues: a dangling defaultPrim and a broken mesh.
        let broken = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh", attributes: [
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 7])),
        ])
        let stage = StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Ghost"),
            rootPrims: [Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [broken])])
        let decision = ExportGate.evaluate(stage: stage, profileID: "arkit")
        #expect(decision.blockingDiagnostics.count == 2)
        #expect(decision.headline == "2 issues block export.")
    }

    @Test func advisoryHeadlinePluralisesCorrectly() {
        let one = ExportGate.evaluate(stage: warningStage(), profileID: "arkit")
        #expect(one.advisoryDiagnostics.count == 1)
        #expect(one.headline == "1 advisory note — export is allowed.")
    }

    // MARK: Override policy

    @Test func overrideLetsABlockedExportProceedButNothingElseChanges() {
        let decision = ExportGate.evaluate(stage: errorStage(), profileID: "arkit")
        #expect(decision.permitsExport(overridden: false) == false)
        #expect(decision.permitsExport(overridden: true))

        // The override is purely permission to proceed — it does not launder the
        // verdict, so the UI keeps showing what is wrong.
        #expect(decision.verdict == .blocked(count: 1))
        #expect(decision.blockingDiagnostics.count == 1)
    }

    @Test func overrideIsANoOpWhenNothingBlocks() {
        for stage in [cleanStage(), warningStage()] {
            let decision = ExportGate.evaluate(stage: stage, profileID: "arkit")
            #expect(decision.permitsExport(overridden: false))
            #expect(decision.permitsExport(overridden: true))
            #expect(!decision.allowsOverride)
        }
    }

    // MARK: Profile selection

    @Test func profileIDRoundTripsSoThePickerStaysInSync() {
        #expect(ExportGate.evaluate(stage: cleanStage(), profileID: "arkit").profileID == "arkit")
        #expect(ExportGate.evaluate(stage: cleanStage(), profileID: "arkit-strict").profileID == "arkit-strict")
    }

    @Test func unknownProfileDegradesToTheDefaultRatherThanWedgingExport() {
        // A stale @AppStorage value must not leave the user unable to export.
        let decision = ExportGate.evaluate(stage: warningStage(), profileID: "profile-from-a-future-build")
        #expect(decision.profileID == "arkit")
        #expect(decision.allowsExport)
    }

    @Test func everyShippedProfileIsSelectableByItsID() {
        for profile in ValidationProfile.all {
            let decision = ExportGate.evaluate(stage: cleanStage(), profileID: profile.id)
            #expect(decision.profileID == profile.id)
            #expect(decision.result.blockingSeverity == profile.blockingSeverity)
        }
    }

    // MARK: Equality (drives SwiftUI re-render)

    @Test func decisionsCompareOnProfileThresholdAndDiagnostics() {
        let a = ExportGate.evaluate(stage: warningStage(), profileID: "arkit")
        let b = ExportGate.evaluate(stage: warningStage(), profileID: "arkit")
        #expect(a == b)

        // Same diagnostics, different threshold → different decision.
        #expect(a != ExportGate.evaluate(stage: warningStage(), profileID: "arkit-strict"))
        // Same profile, different diagnostics → different decision.
        #expect(a != ExportGate.evaluate(stage: cleanStage(), profileID: "arkit"))
    }

    // MARK: Panel wiring

    @MainActor
    @Test func panelWithoutAnEvaluatorShowsNoGateAndStaysExportable() {
        // No document open: the panel must not invent a verdict.
        let panel = ExportPanel(sourceURL: nil, onExport: { _ in }, onClose: {})
        #expect(panel.evaluate == nil)
    }

    @MainActor
    @Test func panelEvaluatorIsCalledWithTheSelectedProfile() {
        var requested: [String] = []
        let panel = ExportPanel(
            sourceURL: nil,
            evaluate: { profileID in
                requested.append(profileID)
                return ExportGate.evaluate(stage: cleanStage(), profileID: profileID)
            },
            onExport: { _ in }, onClose: {})

        let decision = panel.evaluate?("arkit-strict")
        #expect(requested == ["arkit-strict"])
        #expect(decision?.profileID == "arkit-strict")
    }
}
