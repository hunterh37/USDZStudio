import CaptureKit
import ConversionKit
import Foundation
import ImageIO

/// The side-effecting seam behind the capture import UI: it lists the photos in
/// a folder, reads their pixel dimensions, runs the pure pre-flight gate, and
/// drives the reconstruction session that turns the photos into a USDZ.
///
/// Following the repo's clean-architecture rule (CLAUDE.md — "Services
/// encapsulate side effects behind protocols so they can be injected and
/// tested"), the view model depends on this protocol, never on
/// `PhotogrammetrySession` directly. The production implementation
/// (`PhotogrammetryCaptureService`) is the one true hardware/framework seam and
/// is excluded from coverage; `CaptureImportModel` is exercised against an
/// injected fake.
@MainActor
public protocol CaptureImportService: Sendable {
    /// The supported photos found directly inside `folder`, in stable order.
    func images(in folder: URL) -> [URL]

    /// The pure pre-flight verdict for a request, decoding image resolutions so
    /// the mixed-resolution check is meaningful (specs/capture-import.md — step 1).
    func preflight(images: [URL], detail: CaptureDetail, profile: CaptureProfile) -> CaptureQualityReport

    /// Reconstruct the photos into an editable USDZ, streaming progress then a
    /// terminal `.modelReady(url)`. The single non-deterministic step.
    func reconstruct(
        images: [URL],
        detail: CaptureDetail,
        profile: CaptureProfile,
        targetMetersPerUnit: Double?
    ) -> AsyncThrowingStream<CaptureProgress, Error>
}

/// Production capture service: a thin composition of the pure `CapturePlanner`
/// (pre-flight + plan) and the real `PhotogrammetrySessionRunner` (the hardware
/// reconstruction seam). Every line here either touches the filesystem, ImageIO,
/// or the reconstruction seam, so the whole type is coverage-excluded exactly
/// like the runner it wraps; the orchestration logic that *is* covered lives in
/// `CaptureImportModel` and is tested against a fake service.
// coverage:disable — hardware/framework seam: ImageIO decode + PhotogrammetrySession reconstruction; the model that drives this is covered against an injected fake service.
public struct PhotogrammetryCaptureService: CaptureImportService {
    private let planner: any CapturePlanning
    private let makeRunner: @Sendable () -> any PhotogrammetryRunning

    public init(
        planner: any CapturePlanning = CapturePlanner(),
        makeRunner: @escaping @Sendable () -> any PhotogrammetryRunning = {
            if #available(macOS 12.0, *) { PhotogrammetrySessionRunner() }
            else { UnsupportedHostCaptureRunner() }
        }
    ) {
        self.planner = planner
        self.makeRunner = makeRunner
    }

    public func images(in folder: URL) -> [URL] {
        ObjectCaptureImporter.defaultListImages(folder)
    }

    public func preflight(
        images: [URL], detail: CaptureDetail, profile: CaptureProfile
    ) -> CaptureQualityReport {
        let request = CaptureRequest(imageURLs: images, detail: detail, profile: profile)
        return planner.validate(request, imageResolutions: pixelSizes(of: images))
    }

    public func reconstruct(
        images: [URL], detail: CaptureDetail, profile: CaptureProfile, targetMetersPerUnit: Double?
    ) -> AsyncThrowingStream<CaptureProgress, Error> {
        let request = CaptureRequest(
            imageURLs: images, detail: detail,
            targetMetersPerUnit: targetMetersPerUnit, profile: profile)
        return makeRunner().run(planner.plan(request), images: images)
    }

    /// Decode each photo's pixel dimensions via ImageIO header inspection (no
    /// full decode). Returns `nil` when any header can't be read, so the planner
    /// simply skips the resolution check rather than firing a false positive.
    private func pixelSizes(of images: [URL]) -> [PixelSize]? {
        var sizes: [PixelSize] = []
        for url in images {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            sizes.append(PixelSize(width: width, height: height))
        }
        return sizes
    }
}

/// Stand-in reconstruction seam for hosts predating `PhotogrammetrySession`;
/// every run fails with a clear message rather than crashing. Mirrors the CLI's
/// `UnsupportedHostRunner`.
public struct UnsupportedHostCaptureRunner: PhotogrammetryRunning {
    public init() {}
    public func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CaptureImportError.sessionProducedNoModel) }
    }
}
// coverage:enable
