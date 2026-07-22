import USDCore

/// The aggregated result of running a `ValidationEngine` over a stage:
/// diagnostics sorted most-severe first, plus the compliance summary the export
/// gate reads (specs/validation.md — ComplianceChecker gating).
public struct ValidationReport: Sendable, Hashable {
    public var diagnostics: [Diagnostic]

    public init(diagnostics: [Diagnostic] = []) {
        self.diagnostics = diagnostics
    }

    public func count(of severity: DiagnosticSeverity) -> Int {
        diagnostics.lazy.filter { $0.severity == severity }.count
    }

    public var errorCount: Int { count(of: .error) }
    public var warningCount: Int { count(of: .warning) }
    public var infoCount: Int { count(of: .info) }

    /// Export is allowed only when nothing is a hard error. Warnings and info
    /// are surfaced but don't block (PRD §5.4 export gating).
    public var isCompliant: Bool { errorCount == 0 }
}

/// Runs an ordered catalog of `ValidationRule`s over a stage and merges their
/// output. Stateless and `Sendable`, so a single engine can be reused across
/// documents and threads.
public struct ValidationEngine: Sendable {
    public let rules: [any ValidationRule]

    public init(rules: [any ValidationRule]) {
        self.rules = rules
    }

    /// The AR QuickLook / ARKit compatibility profile — the default catalog the
    /// diagnostics drawer and the CLI `validate` subcommand run.
    public static var arkitProfile: ValidationEngine {
        ValidationEngine(rules: [
            MetersPerUnitRule(),
            UpAxisRule(),
            DefaultPrimRule(),
            DuplicatePrimNameRule(),
            MeshTopologyRule(),
            EmptyMeshRule(),
            UnboundMeshRule(),
            MissingNormalsRule(),
            MissingSubdivisionSchemeRule(),
        ])
    }

    public func validate(_ stage: any USDStageProtocol) -> ValidationReport {
        // Index once for the whole catalog. Rules are pure functions of the stage
        // and most of them need a full traversal; without this, an 8-rule profile
        // walked the hierarchy six separate times per pass.
        let indexed = stage.indexed()
        let diagnostics = rules
            .flatMap { $0.evaluate(stage: indexed) }
            .sorted(by: Self.moreSevereFirst)
        return ValidationReport(diagnostics: diagnostics)
    }

    /// Stable ordering: severity descending, then ruleID, then prim path, so the
    /// drawer and golden-file tests see a deterministic list.
    static func moreSevereFirst(_ lhs: Diagnostic, _ rhs: Diagnostic) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.ruleID != rhs.ruleID { return lhs.ruleID < rhs.ruleID }
        return (lhs.primPath?.description ?? "") < (rhs.primPath?.description ?? "")
    }
}
