import CaptureKit
import Foundation
import RealityKit

/// Production `PhotogrammetryRunning` backed by Apple's `PhotogrammetrySession`
/// (RealityKit Object Capture). This is the one true process/framework seam of
/// the capture feature: it needs Apple-silicon hardware, runs a real
/// reconstruction, and is therefore excluded from the coverage gate and never
/// exercised in CI — exactly the discipline the `usdrecord` and Python-bridge
/// seams follow (specs/capture-import.md — Module split).
///
/// The whole type is coverage-excluded: no line here is reachable without the
/// hardware session, and the importer that drives it is fully covered against an
/// injected fake runner.
// coverage:disable — reconstruction seam: real PhotogrammetrySession over Object Capture hardware; unit tests inject a fake PhotogrammetryRunning.
@available(macOS 12.0, *)
public struct PhotogrammetrySessionRunner: PhotogrammetryRunning {
    /// Directory the finished USDZ is written into (a fresh temp dir by default).
    private let outputDirectory: URL

    public init(outputDirectory: URL? = nil) {
        self.outputDirectory = outputDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("openusdz-capture-\(UUID().uuidString)", isDirectory: true)
    }

    /// Maps our detail token back onto `PhotogrammetrySession.Request.Detail`.
    static func sessionDetail(for token: String) -> PhotogrammetrySession.Request.Detail {
        switch token {
        case "preview": return .preview
        case "reduced": return .reduced
        case "full": return .full
        case "raw": return .raw
        default: return .medium
        }
    }

    public func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // The images share a parent folder; the session ingests the folder.
                    let inputFolder = images.first?.deletingLastPathComponent()
                        ?? outputDirectory
                    let session = try PhotogrammetrySession(input: inputFolder)

                    try FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true)
                    let outputURL = outputDirectory.appendingPathComponent("model.usdz")
                    let request = PhotogrammetrySession.Request.modelFile(
                        url: outputURL,
                        detail: Self.sessionDetail(for: plan.sessionDetail))

                    try session.process(requests: [request])

                    for try await output in session.outputs {
                        switch output {
                        case let .requestProgress(_, fractionComplete):
                            continuation.yield(.progress(fractionComplete))
                        case let .requestComplete(_, result):
                            if case let .modelFile(url) = result {
                                continuation.yield(.modelReady(url: url))
                            }
                        case let .requestError(_, error):
                            continuation.finish(throwing: error)
                            return
                        case .processingCancelled:
                            continuation.finish(throwing: CaptureImportError.sessionProducedNoModel)
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
// coverage:enable
