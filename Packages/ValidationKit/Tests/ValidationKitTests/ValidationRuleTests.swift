import Testing
import USDCore
@testable import ValidationKit

@Suite("DiagnosticSeverity")
struct SeverityTests {
    @Test func ordering() {
        #expect(DiagnosticSeverity.info < .warning)
        #expect(DiagnosticSeverity.warning < .error)
        #expect(!(DiagnosticSeverity.error < .error))
    }
}

@Suite("MetersPerUnitRule")
struct MetersPerUnitRuleTests {

    private func stage(metersPerUnit: Double) -> StageSnapshot {
        StageSnapshot(metadata: StageMetadata(metersPerUnit: metersPerUnit))
    }

    @Test(arguments: [1.0, 0.01, 0.0001, 1000.0])
    func passesReasonableScales(_ mpu: Double) {
        #expect(MetersPerUnitRule().evaluate(stage: stage(metersPerUnit: mpu)).isEmpty)
    }

    @Test(arguments: [0.00001, 100000.0])
    func flagsExtremeScales(_ mpu: Double) {
        let diagnostics = MetersPerUnitRule().evaluate(stage: stage(metersPerUnit: mpu))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .warning)
        #expect(diagnostics[0].ruleID == "stage.metersPerUnit")
        #expect(diagnostics[0].primPath == nil)
        #expect(diagnostics[0].message.contains("\(mpu)"))
    }
}
