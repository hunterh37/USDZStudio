import Testing
import Foundation
import CaptureKit
import ConversionKit
@testable import openusdz

@Suite("capture subcommand")
struct CaptureCommandTests {

    private final class Capture: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
        var copies: [(from: URL, to: URL)] = []
    }

    /// A fake reconstruction seam yielding scripted events.
    private struct FakeRunner: PhotogrammetryRunning {
        var events: [CaptureProgress]
        var error: Error?
        func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error> {
            AsyncThrowingStream { c in
                for e in events { c.yield(e) }
                if let error { c.finish(throwing: error) } else { c.finish() }
            }
        }
    }

    private struct FakeError: Error {}

    private func urls(_ n: Int, ext: String = "heic") -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/tmp/cap/img_\($0).\(ext)") }
    }

    private func run(
        _ arguments: [String],
        images: [URL] = [],
        events: [CaptureProgress] = [.modelReady(url: URL(fileURLWithPath: "/tmp/model.usdz"))],
        error: Error? = nil
    ) async -> (Int32, Capture) {
        let capture = Capture()
        let code = await CaptureCommand.run(
            arguments: arguments,
            print: { capture.out.append($0) },
            printError: { capture.err.append($0) },
            listImages: { _ in images },
            makeRunner: { FakeRunner(events: events, error: error) },
            writeOutput: { from, to in capture.copies.append((from, to)) })
        return (code, capture)
    }

    // MARK: valid dir

    @Test func validDirReconstructsAndWrites() async {
        let (code, cap) = await run(["in", "out.usdz", "--detail", "medium"], images: urls(60))
        #expect(code == 0)
        #expect(cap.copies.count == 1)
        #expect(cap.copies[0].to == URL(fileURLWithPath: "out.usdz"))
        #expect(cap.out.contains { $0.contains("wrote") && $0.contains("out.usdz") })
        // medium is diffuse+normal → material caveat surfaced.
        #expect(cap.out.contains { $0.contains("diffuse + normal") })
    }

    @Test func validDirJSON() async throws {
        let (code, cap) = await run(
            ["in", "out.usdz", "--detail", "full", "--meters-per-unit", "0.5", "--json"],
            images: urls(60))
        #expect(code == 0)
        let json = try #require(cap.out.first)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(obj["accepted"] as? Bool == true)
        #expect(obj["detail"] as? String == "full")
        #expect(obj["requestsPBRMaps"] as? Bool == true)
        #expect(obj["imageCount"] as? Int == 60)
    }

    @Test func progressPrintedInHumanMode() async {
        let (code, cap) = await run(
            ["in", "out.usdz"], images: urls(60),
            events: [.progress(0.42), .modelReady(url: URL(fileURLWithPath: "/tmp/m.usdz"))])
        #expect(code == 0)
        #expect(cap.out.contains { $0.contains("42%") })
    }

    @Test func scaleNoteWhenMetersGiven() async {
        let (code, cap) = await run(
            ["in", "out.usdz", "--detail", "raw", "--meters-per-unit", "2"], images: urls(60))
        #expect(code == 0)
        #expect(cap.out.contains { $0.contains("2.0 meters per unit") })
        // raw authors a full PBR set → no diffuse caveat.
        #expect(!cap.out.contains { $0.contains("diffuse") })
    }

    // MARK: too few images

    @Test func tooFewImagesBlocksBeforeSession() async {
        let (code, cap) = await run(["in", "out.usdz"], images: urls(5))
        #expect(code == 1)
        #expect(cap.copies.isEmpty)  // session never ran
        #expect(cap.err.contains { $0.contains("at least 20") })
    }

    @Test func tooFewImagesJSONReportsRejected() async throws {
        let (code, cap) = await run(["in", "out.usdz", "--json"], images: urls(5))
        #expect(code == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(cap.out.first!.utf8)) as! [String: Any]
        #expect(obj["accepted"] as? Bool == false)
    }

    @Test func nearMinimumAdvisoryStillSucceeds() async {
        let (code, cap) = await run(["in", "out.usdz"], images: urls(30))
        #expect(code == 0)
        #expect(cap.err.contains { $0.contains("overlapping angles") })  // advisory on stderr
    }

    // MARK: missing dir / no images

    @Test func missingDirNoImages() async {
        let (code, cap) = await run(["in", "out.usdz"], images: [])
        #expect(code == 1)
        #expect(cap.err.contains { $0.contains("no HEIC/JPEG/PNG images") })
    }

    // MARK: unsupported format

    @Test func unsupportedImageFormatBlocks() async {
        // 60 files but all .gif → validate raises unsupported-format (blocking).
        let (code, cap) = await run(["in", "out.usdz"], images: urls(60, ext: "gif"))
        #expect(code == 1)
        #expect(cap.err.contains { $0.contains("unsupported image format") })
    }

    // MARK: usage / arg errors

    @Test func nonUsdzOutputRejected() async {
        let (code, cap) = await run(["in", "out.usda"], images: urls(60))
        #expect(code == 2)
        #expect(cap.err.contains { $0.contains("must be a .usdz") })
    }

    @Test func missingPositionals() async {
        let (code, _) = await run(["in"], images: urls(60))
        #expect(code == 2)
    }

    @Test func unknownDetail() async {
        let (code, cap) = await run(["in", "out.usdz", "--detail", "ultra"], images: urls(60))
        #expect(code == 2)
        #expect(cap.err.contains { $0.contains("unknown detail 'ultra'") })
    }

    @Test func unknownProfile() async {
        let (code, cap) = await run(["in", "out.usdz", "--profile", "web"], images: urls(60))
        #expect(code == 2)
        #expect(cap.err.contains { $0.contains("unknown profile 'web'") })
    }

    @Test func arkitStrictProfileAccepted() async {
        let (code, _) = await run(["in", "out.usdz", "--profile", "arkit-strict"], images: urls(60))
        #expect(code == 0)
    }

    @Test func detailFlagNeedsValue() async {
        let (code, _) = await run(["in", "out.usdz", "--detail"], images: urls(60))
        #expect(code == 2)
    }

    @Test func profileFlagNeedsValue() async {
        let (code, _) = await run(["in", "out.usdz", "--profile"], images: urls(60))
        #expect(code == 2)
    }

    @Test func metersFlagNeedsPositiveNumber() async {
        let (code, _) = await run(["in", "out.usdz", "--meters-per-unit", "-1"], images: urls(60))
        #expect(code == 2)
        let (code2, _) = await run(["in", "out.usdz", "--meters-per-unit"], images: urls(60))
        #expect(code2 == 2)
    }

    @Test func unknownOption() async {
        let (code, _) = await run(["in", "out.usdz", "--turbo"], images: urls(60))
        #expect(code == 2)
    }

    // MARK: reconstruction failures

    @Test func runnerErrorReported() async {
        let (code, cap) = await run(["in", "out.usdz"], images: urls(60), error: FakeError())
        #expect(code == 1)
        #expect(cap.err.contains { $0.contains("reconstruction failed") })
    }

    @Test func noModelProduced() async {
        let (code, cap) = await run(["in", "out.usdz"], images: urls(60), events: [.progress(0.9)])
        #expect(code == 1)
        #expect(cap.err.contains { $0.contains("produced no model") })
    }

    @Test func writeFailureReported() async {
        let capture = Capture()
        let code = await CaptureCommand.run(
            arguments: ["in", "out.usdz"],
            print: { capture.out.append($0) },
            printError: { capture.err.append($0) },
            listImages: { _ in self.urls(60) },
            makeRunner: { FakeRunner(events: [.modelReady(url: URL(fileURLWithPath: "/tmp/m.usdz"))], error: nil) },
            writeOutput: { _, _ in throw FakeError() })
        #expect(code == 1)
        #expect(capture.err.contains { $0.contains("could not write") })
    }

    // MARK: helpers

    @Test func captureProfileMapping() {
        #expect(CaptureCommand.captureProfile("arkit") == .arkit)
        #expect(CaptureCommand.captureProfile("arkit-strict") == .arkitStrict)
        #expect(CaptureCommand.captureProfile("nope") == nil)
    }

    @Test func defaultWriteOutputCopiesFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capcli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("model.usdz")
        try Data("usdz".utf8).write(to: model)
        let dest = dir.appendingPathComponent("nested/out.usdz")
        // First write creates the nested dir; second exercises the replace path.
        try CaptureCommand.defaultWriteOutput(model, dest)
        try CaptureCommand.defaultWriteOutput(model, dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    // Dispatch through the top-level runner so the `capture` case is covered.
    @Test func dispatchesThroughCLIRunner() async {
        let code = await CLIRunner.run(
            arguments: ["capture", "in", "out.usda"],  // bad ext → usage error, no hardware needed
            print: { _ in }, printError: { _ in })
        #expect(code == 2)
    }
}
