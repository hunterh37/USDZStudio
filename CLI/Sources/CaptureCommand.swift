import CaptureKit
import ConversionKit
import Foundation

/// `openusdz capture <images-dir> <out.usdz> --detail medium [--profile arkit]
/// [--meters-per-unit N] [--json]` — reconstruct a mesh from a folder of photos
/// via `PhotogrammetrySession`, sharing the exact pre-flight gate and plan the
/// in-app importer uses (specs/capture-import.md — Batch & CLI).
///
/// The pure work (arg parsing, pre-flight validate, plan) is fully unit-tested;
/// the reconstruction seam and file copy are injected so the matrix runs
/// headless with no hardware. Exit codes: 0 ok, 1 pre-flight/runtime failure,
/// 2 usage.
enum CaptureCommand {
    /// The reconstruction seam, injected for tests. Defaults to the real
    /// `PhotogrammetrySession` runner (Apple-silicon hardware only).
    // coverage:disable — real reconstruction seam: constructs a PhotogrammetrySession runner; unit tests inject a fake runner.
    static func defaultRunner() -> any PhotogrammetryRunning {
        if #available(macOS 12.0, *) {
            return PhotogrammetrySessionRunner()
        } else {
            return UnsupportedHostRunner()
        }
    }
    // coverage:enable

    static func run(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void,
        planner: any CapturePlanning = CapturePlanner(),
        listImages: (URL) -> [URL] = ObjectCaptureImporter.defaultListImages,
        makeRunner: () -> any PhotogrammetryRunning = CaptureCommand.defaultRunner,
        writeOutput: (URL, URL) throws -> Void = CaptureCommand.defaultWriteOutput
    ) async -> Int32 {
        var positional: [String] = []
        var detailToken = "medium"
        var profileToken = "arkit"
        var meters: Double?
        var json = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--detail":
                guard index + 1 < arguments.count else {
                    printError("error: --detail needs a value (\(CaptureDetail.allCases.map(\.rawValue).joined(separator: ", ")))")
                    return 2
                }
                detailToken = arguments[index + 1]; index += 2
            case "--profile":
                guard index + 1 < arguments.count else {
                    printError("error: --profile needs a value (arkit, arkit-strict)")
                    return 2
                }
                profileToken = arguments[index + 1]; index += 2
            case "--meters-per-unit":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else {
                    printError("error: --meters-per-unit needs a positive number")
                    return 2
                }
                meters = value; index += 2
            case "--json":
                json = true; index += 1
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)\n" + CLIRunner.usage)
                    return 2
                }
                positional.append(argument); index += 1
            }
        }

        guard positional.count == 2 else {
            printError("error: capture needs an images directory and an output path\n" + CLIRunner.usage)
            return 2
        }
        guard let detail = CaptureDetail(rawValue: detailToken) else {
            printError("error: unknown detail '\(detailToken)' (choices: \(CaptureDetail.allCases.map(\.rawValue).joined(separator: ", ")))")
            return 2
        }
        guard let profile = captureProfile(profileToken) else {
            printError("error: unknown profile '\(profileToken)' (choices: arkit, arkit-strict)")
            return 2
        }
        let inputURL = URL(fileURLWithPath: positional[0])
        let outputURL = URL(fileURLWithPath: positional[1])
        guard outputURL.pathExtension.lowercased() == "usdz" else {
            printError("error: capture output must be a .usdz file")
            return 2
        }

        let images = listImages(inputURL)
        guard !images.isEmpty else {
            printError("error: no HEIC/JPEG/PNG images found in \(inputURL.path)")
            return 1
        }

        let request = CaptureRequest(
            imageURLs: images, detail: detail, targetMetersPerUnit: meters, profile: profile)
        let report = planner.validate(request)
        for advisory in report.advisories {
            printError("warning: [capture-preflight] \(advisory.message)")
        }
        guard report.isAcceptable else {
            for issue in report.blockingIssues {
                printError("error: [capture-preflight] \(issue.message)")
            }
            if json {
                output(encodeJSON(file: outputURL.path, detail: detail, plan: planner.plan(request),
                                  imageCount: images.count, accepted: false, advisories: report.advisories))
            }
            return 1
        }

        let plan = planner.plan(request)
        let runner = makeRunner()
        var modelURL: URL?
        do {
            for try await event in runner.run(plan, images: images) {
                switch event {
                case let .progress(fraction):
                    if !json { output("reconstructing… \(Int(fraction * 100))%") }
                case let .modelReady(url):
                    modelURL = url
                }
            }
        } catch {
            printError("error: reconstruction failed: \(error)")
            return 1
        }
        guard let modelURL else {
            printError("error: reconstruction produced no model — add more images or improve lighting")
            return 1
        }

        do {
            try writeOutput(modelURL, outputURL)
        } catch {
            printError("error: could not write \(outputURL.path): \(error)")
            return 1
        }

        if json {
            output(encodeJSON(file: outputURL.path, detail: detail, plan: plan,
                              imageCount: images.count, accepted: true, advisories: report.advisories))
        } else {
            if !plan.requestsPBRMaps {
                output("note: detail \"\(detail.rawValue)\" produces a \(detail.materialSummary) material")
            }
            if let meters { output("note: scale normalized to \(meters) meters per unit") }
            output("wrote \(outputURL.path)")
        }
        return 0
    }

    /// Maps a CLI profile token (`arkit` / `arkit-strict`) to `CaptureProfile`.
    static func captureProfile(_ token: String) -> CaptureProfile? {
        switch token {
        case "arkit": return .arkit
        case "arkit-strict": return .arkitStrict
        default: return nil
        }
    }

    /// Machine-readable report mirroring the human output.
    static func encodeJSON(
        file: String, detail: CaptureDetail, plan: CapturePlan,
        imageCount: Int, accepted: Bool, advisories: [CaptureIssue]
    ) -> String {
        let payload: [String: Any] = [
            "file": file,
            "detail": detail.rawValue,
            "sessionDetail": plan.sessionDetail,
            "requestsPBRMaps": plan.requestsPBRMaps,
            "imageCount": imageCount,
            "accepted": accepted,
            "advisories": advisories.map(\.message),
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Default output writer: copy the session's USDZ to the requested path,
    /// replacing any existing file.
    static func defaultWriteOutput(_ model: URL, _ destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: model, to: destination)
    }
}

/// Stand-in seam used when the host predates `PhotogrammetrySession`; every run
/// fails with a clear unsupported-host message rather than crashing.
// coverage:disable — unsupported-host seam: only constructed on pre-macOS-12 hosts, never in CI.
struct UnsupportedHostRunner: PhotogrammetryRunning {
    func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CaptureImportError.sessionProducedNoModel) }
    }
}
// coverage:enable
