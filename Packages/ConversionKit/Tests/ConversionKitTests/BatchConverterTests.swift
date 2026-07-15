import Testing
import Foundation
import USDCore
@testable import ConversionKit

@Suite("BatchConverter engine")
struct BatchConverterTests {

    /// Captures writes in memory so a batch run touches no real disk.
    private final class Sink: @unchecked Sendable {
        var written: [String: String] = [:]
        func exists(_ url: URL) -> Bool { written[url.path] != nil }
        func write(_ text: String, _ url: URL) { written[url.path] = text }
    }

    private func converter(_ sink: Sink, overwrite: Bool = true) -> BatchConverter {
        BatchConverter(
            overwrite: overwrite,
            fileExists: { sink.exists($0) },
            writeFile: { sink.write($0, $1) })
    }

    @Test func convertsEveryJobAndWritesUSDA() async throws {
        let glb = try GLTFFixtures.write(
            GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN()),
            name: "tri.glb")
        let out = glb.deletingPathExtension().appendingPathExtension("usda")
        let sink = Sink()

        let report = await converter(sink).run([BatchJob(input: glb, output: out)])

        #expect(report.succeededCount == 1)
        #expect(report.failedCount == 0)
        #expect(report.hasFailures == false)
        let item = try #require(report.items.first)
        #expect(item.status == .succeeded)
        #expect(item.triangleCount == 1)
        #expect(item.materialCount == 1)
        #expect(sink.written[out.path]?.contains("#usda") == true)
    }

    @Test func unsupportedInputBecomesFailedRowNotThrow() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("thing.xyz")
        let sink = Sink()

        let report = await converter(sink).run([
            BatchJob(input: bogus, output: bogus.appendingPathExtension("usda"))
        ])

        #expect(report.failedCount == 1)
        #expect(report.hasFailures)
        #expect(report.items.first?.message?.contains("unsupported input") == true)
        #expect(sink.written.isEmpty)
    }

    @Test func oneBadAssetDoesNotAbortTheRest() async throws {
        let good = try GLTFFixtures.write(
            GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN()),
            name: "good.glb")
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad.xyz")
        let sink = Sink()

        let report = await converter(sink).run([
            BatchJob(input: bad, output: bad.appendingPathExtension("usda")),
            BatchJob(input: good, output: good.deletingPathExtension().appendingPathExtension("usda")),
        ])

        #expect(report.items.count == 2)
        #expect(report.succeededCount == 1)
        #expect(report.failedCount == 1)
    }

    @Test func noOverwriteSkipsExistingOutput() async throws {
        let glb = try GLTFFixtures.write(
            GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN()),
            name: "tri.glb")
        let out = glb.deletingPathExtension().appendingPathExtension("usda")
        let sink = Sink()
        sink.written[out.path] = "existing"

        let report = await converter(sink, overwrite: false).run([BatchJob(input: glb, output: out)])

        #expect(report.skippedCount == 1)
        #expect(report.items.first?.status == .skipped)
        #expect(sink.written[out.path] == "existing")  // untouched
    }

    @Test func onProgressStreamsEachResultInOrder() async throws {
        let glb = try GLTFFixtures.write(
            GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN()),
            name: "tri.glb")
        let sink = Sink()
        var seen: [BatchItemStatus] = []

        _ = await converter(sink).run([
            BatchJob(input: URL(fileURLWithPath: "/nope.xyz"), output: URL(fileURLWithPath: "/nope.usda")),
            BatchJob(input: glb, output: glb.deletingPathExtension().appendingPathExtension("usda")),
        ]) { seen.append($0.status) }

        #expect(seen == [.failed, .succeeded])
    }
}

@Suite("BatchReport rendering")
struct BatchReportTests {

    private let sample = BatchReport(items: [
        BatchItemResult(input: "a.glb", output: "a.usda", status: .succeeded,
                        triangleCount: 12, materialCount: 2, warningCount: 1, durationSeconds: 0.5),
        BatchItemResult(input: "weird, name.glb", output: "out.usda", status: .failed,
                        message: "boom \"quoted\"", durationSeconds: 0.1),
    ])

    @Test func csvHasHeaderAndEscapesSpecialChars() {
        let lines = sample.csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "input,output,status,triangles,materials,warnings,errors,seconds,message")
        #expect(lines[1].contains("a.glb,a.usda,succeeded,12,2,1,0,0.500,"))
        // comma-containing and quote-containing fields get quoted/doubled.
        #expect(lines[2].contains("\"weird, name.glb\""))
        #expect(lines[2].contains("\"boom \"\"quoted\"\"\""))
    }

    @Test func jsonRoundTrips() throws {
        let data = try sample.jsonData()
        let decoded = try JSONDecoder().decode(BatchReport.self, from: data)
        #expect(decoded == sample)
        #expect(decoded.succeededCount == 1)
        #expect(decoded.failedCount == 1)
    }
}
