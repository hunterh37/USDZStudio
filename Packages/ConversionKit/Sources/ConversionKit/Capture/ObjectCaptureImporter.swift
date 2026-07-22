import CaptureKit
import Foundation

/// Progress emitted by the reconstruction seam as it runs.
public enum CaptureProgress: Sendable, Equatable {
    /// Fractional progress in `0...1`.
    case progress(Double)
    /// The finished USDZ is ready at `url`.
    case modelReady(url: URL)
}

/// The single non-deterministic, non-covered seam: it wraps
/// `PhotogrammetrySession` (or any reconstruction backend) behind a protocol so
/// the importer's orchestration stays pure and unit-testable with a fake runner
/// (specs/capture-import.md — Principles, "Deterministic outside the seam").
public protocol PhotogrammetryRunning: Sendable {
    /// Reconstruct `images` per `plan`, streaming progress then a `.modelReady`.
    func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error>
}

/// Typed failures from a capture import. Each carries a `recoverySuggestion` so
/// the UI/CLI can tell the user what to do rather than failing opaquely
/// (specs/capture-import.md — Risks: unsupported host, empty geometry).
public enum CaptureImportError: Error, Equatable {
    /// Pre-flight found blocking issues; the session never ran.
    case rejected(messages: [String])
    /// No images were found at the supplied location.
    case noImages(location: String)
    /// The session finished without ever yielding a model.
    case sessionProducedNoModel

    public var recoverySuggestion: String {
        switch self {
        case .rejected:
            return "Fix the blocking issues above — add more overlapping photos at a consistent resolution — and try again."
        case .noImages:
            return "Point the importer at a folder of HEIC/JPEG/PNG photos of a single object."
        case .sessionProducedNoModel:
            return "The reconstruction produced no geometry. Add more images, improve lighting, and ensure the object fills the frame."
        }
    }
}

/// Imports a folder of photographs as an editable USD scene by driving Apple's
/// `PhotogrammetrySession` behind an injected seam. Conforms to `AssetImporter`
/// so a finished capture flows through the exact same post-import machinery
/// (naming, textures, USD authoring, `ScaleFixer`, export gate) as any other
/// asset (specs/capture-import.md — "Output is a normal stage").
public struct ObjectCaptureImporter: AssetImporter {
    /// A `.capture` manifest / image folder handle.
    public static let supportedExtensions = ["capture"]

    /// Image extensions gathered from a capture directory.
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    private let runner: any PhotogrammetryRunning
    private let planner: any CapturePlanning
    private let detail: CaptureDetail
    private let profile: CaptureProfile
    private let targetMetersPerUnit: Double?
    private let listImages: @Sendable (URL) -> [URL]
    private let readScene: @Sendable (URL, ImportOptions) async throws -> ImportResult

    public init(
        runner: any PhotogrammetryRunning,
        planner: any CapturePlanning = CapturePlanner(),
        detail: CaptureDetail = .medium,
        profile: CaptureProfile = .arkit,
        targetMetersPerUnit: Double? = nil,
        listImages: @escaping @Sendable (URL) -> [URL] = ObjectCaptureImporter.defaultListImages,
        readScene: @escaping @Sendable (URL, ImportOptions) async throws -> ImportResult
            = ObjectCaptureImporter.defaultReadScene
    ) {
        self.runner = runner
        self.planner = planner
        self.detail = detail
        self.profile = profile
        self.targetMetersPerUnit = targetMetersPerUnit
        self.listImages = listImages
        self.readScene = readScene
    }

    public func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult {
        let images = listImages(url)
        guard !images.isEmpty else {
            throw CaptureImportError.noImages(location: url.path)
        }

        let request = CaptureRequest(
            imageURLs: images, detail: detail,
            targetMetersPerUnit: targetMetersPerUnit, profile: profile)

        // 1. validate (pure) — blocking issues stop before the expensive session.
        let report = planner.validate(request)
        guard report.isAcceptable else {
            throw CaptureImportError.rejected(messages: report.blockingIssues.map(\.message))
        }

        // 2. session (seam) — stream progress, capture the finished model URL.
        let plan = planner.plan(request)
        var modelURL: URL?
        for try await event in runner.run(plan, images: images) {
            if case let .modelReady(url) = event { modelURL = url }
        }
        guard let modelURL else { throw CaptureImportError.sessionProducedNoModel }

        // 3. normalize — read the produced USDZ into the IR; downstream stages
        //    (ScaleFixer, USD authoring) run through the standard pipeline.
        var result = try await readScene(modelURL, options)

        // 4. validateOutput advisories — surface, never launder. Advisory
        //    pre-flight notes plus the honest material caveat travel with the result.
        result.diagnostics.append(contentsOf: captureDiagnostics(report: report, plan: plan))
        return result
    }

    /// Non-blocking diagnostics attached to a successful import: pre-flight
    /// advisories, the diffuse-only caveat for lower tiers, and a scale note.
    func captureDiagnostics(report: CaptureQualityReport, plan: CapturePlan) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = report.advisories.map {
            Diagnostic(severity: .warning, stage: "capture-preflight", message: $0.message)
        }
        if !plan.requestsPBRMaps {
            diagnostics.append(Diagnostic(
                severity: .info, stage: "capture",
                message: "detail \"\(plan.sessionDetail)\" produces a \(detail.materialSummary) material; use .full or .raw for a full PBR set"))
        }
        if let target = targetMetersPerUnit {
            diagnostics.append(Diagnostic(
                severity: .info, stage: "capture",
                message: "scale will be normalized to \(target) meters per unit"))
        }
        return diagnostics
    }

    // MARK: - Injected default behaviors

    /// Gather supported image files from a capture location: the directory
    /// itself, or the parent directory of a `.capture` manifest file. Sorted for
    /// determinism (`PhotogrammetrySession` treats the set as unordered, but a
    /// stable order keeps our logs and any filename-order heuristics reproducible).
    public static let defaultListImages: @Sendable (URL) -> [URL] = { url in
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        let directory = isDir.boolValue ? url : url.deletingLastPathComponent()
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // coverage:disable — ModelIO USDZ decode: reads the reconstruction's output
    // file through the platform loader. The importer's orchestration is covered
    // with an injected reader; the fixture-backed test drives a real ModelIO read.
    public static let defaultReadScene: @Sendable (URL, ImportOptions) async throws -> ImportResult = { url, options in
        try await ModelIOImporter().importAsset(at: url, options: options)
    }
    // coverage:enable
}
