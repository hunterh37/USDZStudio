import Testing
import Foundation
import ConversionKit
@testable import openusdz

@Suite("recolor subcommand")
struct RecolorCommandTests {

    private final class Capture: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
        var written: [URL: Data] = [:]
    }

    /// A small red PNG used as the input texture.
    private func redPNG() throws -> Data {
        try RGBAImageCodec.encodePNG(RGBAImage(width: 8, height: 8, fill: (200, 40, 40, 255)))
    }

    private func run(_ arguments: [String], input: Data?) -> (Int32, Capture) {
        let capture = Capture()
        let code = RecolorCommand.run(
            arguments: arguments,
            print: { capture.out.append($0) },
            printError: { capture.err.append($0) },
            writeFile: { data, url in capture.written[url] = data },
            readFile: { _ in
                guard let input else { throw CocoaError(.fileReadNoSuchFile) }
                return input
            })
        return (code, capture)
    }

    @Test func recolorsAnImageAndWritesPNG() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0"], input: try redPNG())
        #expect(code == 0)
        #expect(capture.written.count == 1)
        let outData = capture.written[URL(fileURLWithPath: "out.png")]!
        let decoded = try RGBAImageCodec.decode(outData)
        #expect(decoded.pixel(x: 0, y: 0) != (200, 40, 40, 255))
        #expect(capture.out.first?.contains("ΔE") == true)
    }

    @Test func calibratedJSONReportsDeltaE() throws {
        let (code, capture) = run(
            ["in.png", "out.png", "--color", "#1B7F3A", "--mode", "calibrated", "--json"],
            input: try redPNG())
        #expect(code == 0)
        let report = try JSONDecoder().decode(RecolorCommand.Report.self, from: Data(capture.out.joined().utf8))
        #expect(report.mode == "calibrated")
        #expect(report.width == 8 && report.height == 8)
        #expect(report.achievedDeltaE < 2.0)
    }

    @Test func maskUVLimitsRecolor() throws {
        let (code, capture) = run(
            ["in.png", "out.png", "--color", "#2040E0", "--mask-uv", "0.0,0.0", "--mask-threshold", "0.05"],
            input: try redPNG())
        #expect(code == 0)
        let decoded = try RGBAImageCodec.decode(capture.written.values.first!)
        // Whole swatch is uniform red, so a low threshold still selects it all;
        // the point is the mask path runs and produces a valid image.
        #expect(decoded.width == 8)
    }

    @Test func allSpacesAndKnobsParse() throws {
        let (code, _) = run(
            ["in.png", "out.png", "--color", "#2040E0",
             "--source-space", "linear", "--target-space", "displayP3",
             "--lightness-bias", "0.1", "--chroma-preservation", "0.5",
             "--preserve-hue-variation"],
            input: try redPNG())
        #expect(code == 0)
    }

    // MARK: - Usage / error paths

    @Test func missingColorFails() throws {
        let (code, capture) = run(["in.png", "out.png"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--color") })
    }

    @Test func badColorFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "nope"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("invalid --color") })
    }

    @Test func wrongPositionalCountFails() throws {
        let (code, _) = run(["only-one.png", "--color", "#2040E0"], input: try redPNG())
        #expect(code == 2)
    }

    @Test func unknownOptionFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0", "--bogus"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("unknown option") })
    }

    @Test func badModeFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0", "--mode", "wild"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--mode") })
    }

    @Test func badSourceSpaceFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0", "--source-space", "cmyk"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--source-space") })
    }

    @Test func badTargetSpaceFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0", "--target-space", "cmyk"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--target-space") })
    }

    @Test func badNumericFlagsFail() throws {
        for flag in ["--lightness-bias", "--chroma-preservation", "--mask-threshold"] {
            let (code, _) = run(["in.png", "out.png", "--color", "#2040E0", flag, "nan-value"], input: try redPNG())
            #expect(code == 2)
        }
    }

    @Test func badMaskUVFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0", "--mask-uv", "0.5"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--mask-uv") })
    }

    @Test func danglingValueFlagFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("--color needs a value") })
    }

    @Test func primPathIsRejectedAsPhase7() throws {
        let (code, capture) = run(["in.usdz", "out.usdz", "--color", "#2040E0", "--prim", "/Car/Body"], input: try redPNG())
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains("Phase 7") })
    }

    @Test func unreadableInputFails() throws {
        let (code, capture) = run(["missing.png", "out.png", "--color", "#2040E0"], input: nil)
        #expect(code == 1)
        #expect(capture.err.contains { $0.contains("cannot read") })
    }

    @Test func undecodableInputFails() throws {
        let (code, capture) = run(["in.png", "out.png", "--color", "#2040E0"], input: Data([0, 1, 2, 3]))
        #expect(code == 1)
        #expect(capture.err.contains { $0.contains("recolor failed") })
    }
}
