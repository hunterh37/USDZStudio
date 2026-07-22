import Foundation

/// The pure capture-planning surface: a deterministic pre-flight gate and a
/// deterministic plan generator. No I/O, no session, no image decoding — the
/// caller supplies image resolutions when a resolution check is wanted.
public protocol CapturePlanning: Sendable {
    /// Pre-flight validation. `imageResolutions`, when supplied, must be parallel
    /// to `request.imageURLs`; when `nil`, the resolution check is skipped.
    func validate(_ request: CaptureRequest, imageResolutions: [PixelSize]?) -> CaptureQualityReport
    /// Deterministic plan for a request (independent of pre-flight verdict).
    func plan(_ request: CaptureRequest) -> CapturePlan
}

extension CapturePlanning {
    /// Validate without a resolution check (URLs and count only).
    public func validate(_ request: CaptureRequest) -> CaptureQualityReport {
        validate(request, imageResolutions: nil)
    }
}

/// The stock planner. Thresholds are intentionally conservative (a product call
/// per specs/capture-import.md — Risks) and expressed as parameters so they can
/// be tuned against real captures without touching the logic.
public struct CapturePlanner: CapturePlanning {
    /// Below this many images the capture is rejected outright.
    public let minimumImages: Int
    /// At or above `minimumImages` but below this, a low-overlap advisory fires.
    public let advisoryImages: Int
    /// Lowercased extensions `PhotogrammetrySession` accepts as input.
    public let supportedExtensions: Set<String>

    public init(
        minimumImages: Int = 20,
        advisoryImages: Int = 50,
        supportedExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
    ) {
        self.minimumImages = minimumImages
        self.advisoryImages = advisoryImages
        self.supportedExtensions = supportedExtensions
    }

    public func validate(_ request: CaptureRequest, imageResolutions: [PixelSize]?) -> CaptureQualityReport {
        var issues: [CaptureIssue] = []

        // Blocking, in severity order. Unsupported formats first (a mis-supplied
        // file is the most concrete fault), then the count floor, then resolution.
        for url in request.imageURLs
        where !supportedExtensions.contains(url.pathExtension.lowercased()) {
            issues.append(.unsupportedImageFormat(url))
        }

        let count = request.imageURLs.count
        if count < minimumImages {
            issues.append(.tooFewImages(count: count, minimum: minimumImages))
        }

        if let resolutions = imageResolutions, Set(resolutions).count > 1 {
            issues.append(.mixedResolution)
        }

        // Advisory: enough to run, but overlap is likely thin. Only meaningful
        // once the count clears the floor (below the floor is already blocking).
        if count >= minimumImages && count < advisoryImages {
            issues.append(.lowOverlapHint)
        }

        return CaptureQualityReport(issues: issues)
    }

    public func plan(_ request: CaptureRequest) -> CapturePlan {
        CapturePlan(
            stages: CaptureStageID.allCases,
            sessionDetail: request.detail.sessionToken,
            requestsPBRMaps: request.detail.requestsPBRMaps
        )
    }
}
