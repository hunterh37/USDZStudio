import CaptureKit
import ConversionKit
import Foundation
import Observation

/// View state + orchestration for the capture-import sheet (photos → editable
/// USDZ). An `@Observable @MainActor` view model per CLAUDE.md: it owns the
/// selected folder, detail/profile options, the live pre-flight verdict, and the
/// reconstruction phase, delegating every side effect to an injected
/// `CaptureImportService` so the whole flow is unit-testable with a fake.
@Observable
@MainActor
public final class CaptureImportModel {

    /// Where the reconstruction currently stands. Drives the sheet's progress,
    /// completion, and error UI.
    public enum Phase: Equatable, Sendable {
        case idle
        case reconstructing(fraction: Double)
        case completed(url: URL)
        case failed(message: String)
    }

    // MARK: Inputs (bound by the sheet)

    /// The chosen folder of photos; `nil` until the user picks/drops one.
    public private(set) var folder: URL?
    /// Fidelity tier requested from the reconstruction (drives the material caveat).
    public var detail: CaptureDetail = .medium { didSet { refreshPreflight() } }
    /// Compliance profile the finished capture is gated against downstream.
    public var profile: CaptureProfile = .arkit { didSet { refreshPreflight() } }
    /// When on, the imported stage is normalized to `metersPerUnit` via ScaleFixer.
    public var normalizeScale = false
    /// Target absolute scale, used only when `normalizeScale` is on.
    public var metersPerUnit: Double = 1.0

    // MARK: Derived / output state

    /// Supported photos found in `folder`, in stable order.
    public private(set) var images: [URL] = []
    /// The latest pre-flight verdict; `nil` before a folder is chosen.
    public private(set) var report: CaptureQualityReport?
    /// The reconstruction phase.
    public private(set) var phase: Phase = .idle

    private let service: any CaptureImportService
    private var runTask: Task<Void, Never>?

    public init(service: any CaptureImportService) {
        self.service = service
    }

    // MARK: Derived UI predicates

    /// `true` while a reconstruction is in flight.
    public var isRunning: Bool {
        if case .reconstructing = phase { return true }
        return false
    }

    /// Whether the Start button is enabled: photos present, pre-flight passes,
    /// and nothing already running.
    public var canStart: Bool {
        !images.isEmpty && (report?.isAcceptable ?? false) && !isRunning
    }

    /// Blocking issues to render (disable Start). Empty when acceptable.
    public var blockingIssues: [CaptureIssue] { report?.blockingIssues ?? [] }

    /// Advisory issues to render (non-blocking).
    public var advisories: [CaptureIssue] { report?.advisories ?? [] }

    /// Show the capture-guidance checklist when an overlap/near-minimum advisory
    /// fires — quality guidance is part of the feature (specs/capture-import.md — UI).
    public var showsGuidance: Bool { !advisories.isEmpty }

    /// Plain-language caveat about the material this tier yields, so a user is
    /// never surprised by a flat diffuse-only result.
    public var materialCaveat: String {
        detail.requestsPBRMaps
            ? "Produces a full PBR material (\(detail.materialSummary))."
            : "Produces a \(detail.materialSummary) material — choose Full or Raw for a complete PBR set."
    }

    /// The finished USDZ once a capture completes, else `nil`.
    public var producedURL: URL? {
        if case let .completed(url) = phase { return url }
        return nil
    }

    /// Human-readable failure message once a capture fails, else `nil`.
    public var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    // MARK: Actions

    /// Adopt a chosen folder: gather its photos and run the pre-flight gate. A
    /// fresh selection clears any prior run outcome.
    public func selectFolder(_ url: URL) {
        folder = url
        images = service.images(in: url)
        phase = .idle
        refreshPreflight()
    }

    /// Recompute the pre-flight verdict for the current photos/options. A no-op
    /// with no folder chosen (nothing to validate yet).
    public func refreshPreflight() {
        guard folder != nil else { return }
        report = service.preflight(images: images, detail: detail, profile: profile)
    }

    /// Kick off reconstruction. Streams progress into `phase`; on the terminal
    /// `.modelReady`, transitions to `.completed` and invokes `onComplete` with
    /// the produced USDZ so the shell can open it as an editable document. Guards
    /// against a double-start and against a run with no acceptable pre-flight.
    public func start(onComplete: @escaping (URL) async -> Void) {
        guard canStart else { return }
        phase = .reconstructing(fraction: 0)
        let target = normalizeScale ? metersPerUnit : nil
        let stream = service.reconstruct(
            images: images, detail: detail, profile: profile, targetMetersPerUnit: target)
        runTask = Task { [weak self] in
            do {
                var produced: URL?
                for try await event in stream {
                    switch event {
                    case let .progress(fraction):
                        self?.phase = .reconstructing(fraction: fraction)
                    case let .modelReady(url):
                        produced = url
                    }
                }
                guard let self else { return }
                if let produced {
                    self.phase = .completed(url: produced)
                    await onComplete(produced)
                } else {
                    self.phase = .failed(
                        message: CaptureImportError.sessionProducedNoModel.recoverySuggestion)
                }
            } catch {
                self?.phase = .failed(message: Self.describe(error))
            }
        }
    }

    /// Cancel an in-flight reconstruction and return to idle.
    public func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning { phase = .idle }
    }

    /// A user-facing message for a reconstruction error, preferring the typed
    /// capture error's recovery suggestion.
    static func describe(_ error: Error) -> String {
        if let captureError = error as? CaptureImportError {
            return captureError.recoverySuggestion
        }
        return error.localizedDescription
    }
}
