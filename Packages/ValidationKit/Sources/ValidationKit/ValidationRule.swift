import USDCore

public enum DiagnosticSeverity: String, Sendable, Comparable {
    case info, warning, error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct Diagnostic: Hashable, Sendable {
    public var ruleID: String
    public var severity: DiagnosticSeverity
    public var message: String
    public var primPath: PrimPath?

    public init(ruleID: String, severity: DiagnosticSeverity, message: String, primPath: PrimPath? = nil) {
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.primPath = primPath
    }
}

/// Extension point for AR QuickLook compatibility rules
/// (specs/validation.md; the v1 rule catalog is Phase 4).
public protocol ValidationRule: Sendable {
    var id: String { get }
    var severity: DiagnosticSeverity { get }
    func evaluate(stage: any USDStageProtocol) -> [Diagnostic]
}

/// First real rule, shipped early because Phase 0 already surfaces metadata:
/// stages destined for AR should declare sensible real-world scale.
public struct MetersPerUnitRule: ValidationRule {
    public let id = "stage.metersPerUnit"
    public let severity = DiagnosticSeverity.warning

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        // AR QuickLook treats geometry as meters; extreme unit scales are the
        // classic "my model is 100× too big" bug (PRD §5.3 scale fixer).
        let mpu = stage.metadata.metersPerUnit
        guard mpu < 0.0001 || mpu > 1000 else { return [] }
        return [Diagnostic(
            ruleID: id,
            severity: severity,
            message: "metersPerUnit is \(mpu); AR QuickLook expects real-world scale. Use the Scale Fixer before export.")]
    }
}
