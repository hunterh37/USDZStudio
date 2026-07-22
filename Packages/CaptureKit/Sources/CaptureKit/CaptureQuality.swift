import Foundation

/// A single problem found by the pre-flight capture gate. Blocking issues stop
/// the pipeline *before* the expensive reconstruction session; advisories are
/// surfaced but never block (specs/capture-import.md — Pipeline model, step 1).
public enum CaptureIssue: Sendable, Equatable {
    /// Fewer photos than the reconstruction floor — blocking.
    case tooFewImages(count: Int, minimum: Int)
    /// The source photos are not all the same resolution — blocking, because
    /// mixed resolutions degrade `PhotogrammetrySession` alignment.
    case mixedResolution
    /// Enough to run, but below the count where overlap is comfortable — advisory.
    case lowOverlapHint
    /// A source file whose extension isn't a supported image format — blocking.
    case unsupportedImageFormat(URL)

    /// Whether this issue blocks the pipeline. Advisories (`lowOverlapHint`)
    /// inform the user without stopping the run.
    public var isBlocking: Bool {
        switch self {
        case .tooFewImages, .mixedResolution, .unsupportedImageFormat:
            return true
        case .lowOverlapHint:
            return false
        }
    }

    /// Human-readable, actionable description of the issue.
    public var message: String {
        switch self {
        case let .tooFewImages(count, minimum):
            return "only \(count) image\(count == 1 ? "" : "s") supplied; at least \(minimum) are needed for a reliable reconstruction"
        case .mixedResolution:
            return "source images have mixed resolutions; capture every photo at the same resolution"
        case .lowOverlapHint:
            return "image count is near the minimum; add more overlapping angles (multiple heights, ~equidistant) for a cleaner mesh"
        case let .unsupportedImageFormat(url):
            return "unsupported image format: \(url.lastPathComponent) (use HEIC, JPEG, or PNG)"
        }
    }
}

/// The verdict of the pre-flight gate: every issue found, most severe first
/// (blocking before advisory). Acceptable when no blocking issue is present.
public struct CaptureQualityReport: Sendable, Equatable {
    public let issues: [CaptureIssue]

    public init(issues: [CaptureIssue]) {
        self.issues = issues
    }

    /// `true` when nothing blocks the reconstruction (advisories are allowed).
    public var isAcceptable: Bool { issues.allSatisfy { !$0.isBlocking } }

    /// Only the blocking issues, in report order.
    public var blockingIssues: [CaptureIssue] { issues.filter { $0.isBlocking } }

    /// Only the advisory (non-blocking) issues, in report order.
    public var advisories: [CaptureIssue] { issues.filter { !$0.isBlocking } }
}
