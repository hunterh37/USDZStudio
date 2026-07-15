import USDCore

/// A named validation profile: the rule catalog to run plus the severity at
/// which a diagnostic *blocks* export. Profiles are the unit the export gate and
/// the CLI select by name, so "which rules + how strict" travels as one value
/// (specs/validation.md — ComplianceChecker gating).
public struct ValidationProfile: Sendable {
    public let id: String
    public let engine: ValidationEngine
    /// Diagnostics at or above this severity block export; below it they are
    /// advisory. `.error` is the AR QuickLook default; `.warning` is strict.
    public let blockingSeverity: DiagnosticSeverity

    public init(id: String, engine: ValidationEngine, blockingSeverity: DiagnosticSeverity = .error) {
        self.id = id
        self.engine = engine
        self.blockingSeverity = blockingSeverity
    }

    /// AR QuickLook / ARKit compatibility. Hard errors block export; warnings
    /// and info are surfaced but don't gate.
    public static var arkit: ValidationProfile {
        ValidationProfile(id: "arkit", engine: .arkitProfile, blockingSeverity: .error)
    }

    /// Same catalog as `.arkit`, but warnings block too — the "everything must
    /// be clean" gate (the exporter's opt-in strict mode, CLI `--strict`).
    public static var arkitStrict: ValidationProfile {
        ValidationProfile(id: "arkit-strict", engine: .arkitProfile, blockingSeverity: .warning)
    }

    /// The catalog of profiles the CLI and UI can select by name.
    public static let all: [ValidationProfile] = [.arkit, .arkitStrict]

    /// Case-insensitive lookup by `id`.
    public static func named(_ id: String) -> ValidationProfile? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public static var identifiers: String { all.map(\.id).joined(separator: ", ") }
}

/// The result of a compliance check: the full diagnostic report plus the gate
/// decision derived from the profile's `blockingSeverity`. This is what the
/// export path reads — `isExportAllowed` decides go/no-go, `blockingDiagnostics`
/// tells the user exactly what to fix first.
public struct ComplianceResult: Sendable {
    public let profileID: String
    public let blockingSeverity: DiagnosticSeverity
    public let report: ValidationReport

    public init(profileID: String, blockingSeverity: DiagnosticSeverity, report: ValidationReport) {
        self.profileID = profileID
        self.blockingSeverity = blockingSeverity
        self.report = report
    }

    /// Diagnostics severe enough to block export, most-severe first (the report
    /// is already sorted, so filtering preserves order).
    public var blockingDiagnostics: [Diagnostic] {
        report.diagnostics.filter { $0.severity >= blockingSeverity }
    }

    /// Export is permitted only when nothing meets the blocking threshold.
    public var isExportAllowed: Bool { blockingDiagnostics.isEmpty }

    /// One-line human summary for logs and the export sheet.
    public var summary: String {
        let counts = "\(report.errorCount) error\(report.errorCount == 1 ? "" : "s"), "
            + "\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s"), "
            + "\(report.infoCount) info"
        let verdict = isExportAllowed ? "export allowed" : "export blocked (\(blockingDiagnostics.count))"
        return "[\(profileID)] \(counts) — \(verdict)"
    }
}

/// Runs a `ValidationProfile` over a stage and produces the export-gate
/// decision. Stateless and `Sendable`, so one checker can serve the diagnostics
/// drawer, the export path, and the CLI.
public struct ComplianceChecker: Sendable {
    public let profile: ValidationProfile

    public init(profile: ValidationProfile = .arkit) {
        self.profile = profile
    }

    public func check(_ stage: any USDStageProtocol) -> ComplianceResult {
        ComplianceResult(
            profileID: profile.id,
            blockingSeverity: profile.blockingSeverity,
            report: profile.engine.validate(stage))
    }
}
