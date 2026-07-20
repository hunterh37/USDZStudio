import Foundation
import USDCore
import ValidationKit

/// The export path's compliance gate: runs a `ValidationProfile` over the live
/// stage and turns the result into the go/no-go the export UI presents
/// (ROADMAP Milestone 5 — "wire the export path through `ComplianceChecker`
/// gating in the app UI").
///
/// Pure value logic with no SwiftUI and no I/O, so the policy — what blocks,
/// what merely warns, what an override is allowed to bypass — is unit-tested
/// directly rather than through a view. `ExportPanel` and the one-click
/// `ExportButton` both render a `Decision`; neither computes one.
///
/// **Override policy.** A blocked export is *overridable*, not forbidden. The
/// gate's job is to make sure nobody ships a broken asset by accident, not to
/// hold a user's own scene hostage: the file is theirs, and there are real
/// workflows (handing a known-imperfect intermediate to another tool, exporting
/// USDA purely to diff it) where the diagnostics are understood and irrelevant.
/// So blocking diagnostics disable the primary button and surface a separate,
/// explicitly-labelled "Export anyway" affordance — a second, deliberate action
/// rather than a dialog the user can dismiss by reflex.
public enum ExportGate {

    /// What the gate decided, and everything the UI needs to explain it.
    /// `ComplianceResult` is not `Equatable` (it carries a whole report), so
    /// equality is defined here on the fields a view actually re-renders from:
    /// the profile, the gate threshold, and the diagnostics themselves.
    public struct Decision: Sendable {
        /// The compliance run behind this decision.
        public let result: ComplianceResult
        /// The profile the user selected, carried so the picker can round-trip.
        public let profileID: String

        public init(result: ComplianceResult, profileID: String) {
            self.result = result
            self.profileID = profileID
        }

        /// Three states, because the UI treats them differently: clean exports
        /// silently, advisory shows a note but does not gate, blocked stops the
        /// primary action.
        public enum Verdict: Sendable, Equatable {
            /// Nothing to report at all.
            case clean
            /// Diagnostics exist, but none meet the profile's blocking bar.
            case advisory
            /// At least one diagnostic blocks; `count` is how many.
            case blocked(count: Int)
        }

        public var verdict: Verdict {
            let blocking = result.blockingDiagnostics.count
            if blocking > 0 { return .blocked(count: blocking) }
            return result.report.diagnostics.isEmpty ? .clean : .advisory
        }

        /// Diagnostics that stop the export, most-severe first.
        public var blockingDiagnostics: [Diagnostic] { result.blockingDiagnostics }

        /// Diagnostics worth showing but not worth gating on, most-severe first.
        public var advisoryDiagnostics: [Diagnostic] {
            result.report.diagnostics.filter { $0.severity < result.blockingSeverity }
        }

        /// Whether the primary "Export" action is enabled.
        public var allowsExport: Bool { result.isExportAllowed }

        /// Whether the secondary "Export anyway" escape hatch should appear.
        /// Only ever shown when something is actually blocking.
        public var allowsOverride: Bool { !allowsExport }

        /// Whether an export may proceed given the user's override choice. The
        /// single predicate the export action calls — no view re-derives this.
        public func permitsExport(overridden: Bool) -> Bool {
            allowsExport || overridden
        }

        /// One-line status for the panel header.
        public var headline: String {
            switch verdict {
            case .clean:
                return "Passes the \(profileID) profile."
            case .advisory:
                let n = advisoryDiagnostics.count
                return "\(n) advisory note\(n == 1 ? "" : "s") — export is allowed."
            case .blocked(let count):
                return "\(count) issue\(count == 1 ? "" : "s") block\(count == 1 ? "s" : "") export."
            }
        }

        /// SF Symbol paired with the verdict.
        public var systemImage: String {
            switch verdict {
            case .clean: return "checkmark.seal.fill"
            case .advisory: return "info.circle.fill"
            case .blocked: return "exclamationmark.triangle.fill"
            }
        }
    }

    /// Evaluates `stage` against the profile named `profileID`, falling back to
    /// the default ARKit profile when the name is unknown (a stale `@AppStorage`
    /// value must not wedge the export path — it degrades to the safe default).
    public static func evaluate(
        stage: any USDStageProtocol,
        profileID: String
    ) -> Decision {
        let profile = ValidationProfile.named(profileID) ?? .arkit
        return Decision(
            result: ComplianceChecker(profile: profile).check(stage),
            profileID: profile.id)
    }
}

extension ExportGate.Decision: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID == rhs.profileID
            && lhs.result.blockingSeverity == rhs.result.blockingSeverity
            && lhs.result.report.diagnostics == rhs.result.report.diagnostics
    }
}
