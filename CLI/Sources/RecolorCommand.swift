import ConversionKit
import Foundation

/// `openusdz recolor <in.png> <out.png> --color '#RRGGBB' [options]` — perceptual
/// texture recoloring from the command line (specs/recoloring.md §Scripting &
/// Batch). Recolors a standalone albedo texture (the e-commerce "rebrand 200
/// SKUs" workflow, driven per-file or from `recolor_batch.py`) while preserving
/// grain, weave, and shading via the OKLab `RecolorEngine`.
///
/// The `--prim /Path` form (recolor a part inside a `.usdz`) is reserved: it
/// needs `UsdUVTexture`-network authoring in `USDAuthorStage`, a Phase 7 gap
/// (see ROADMAP Phase 7 / the Phase 3 texture-replace TODO). Until then this
/// command operates on loose texture images, which is exactly what the batch
/// rebrand workflow consumes.
enum RecolorCommand {
    static func run(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void,
        writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1) },
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> Int32 {
        var positional: [String] = []
        var color: String?
        var mode = RecolorMode.direct
        var sourceSpace = TextureColorSpace.sRGB
        var targetSpace = TextureColorSpace.sRGB
        var lightnessBias = 0.0
        var chromaPreservation = 1.0
        var preserveHueVariation = false
        var maskUV: (u: Double, v: Double)?
        var maskThreshold = 0.1
        var json = false
        var prim: String?

        var index = 0
        let args = arguments
        func nextValue(_ flag: String) -> String? {
            index += 1
            guard index < args.count else {
                printError("error: \(flag) needs a value\n" + CLIRunner.usage)
                return nil
            }
            return args[index]
        }

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--color":
                guard let value = nextValue(argument) else { return 2 }
                color = value
            case "--mode":
                guard let value = nextValue(argument) else { return 2 }
                guard let parsed = RecolorMode(rawValue: value) else {
                    printError("error: --mode must be one of: \(RecolorMode.allCases.map(\.rawValue).joined(separator: ", "))")
                    return 2
                }
                mode = parsed
            case "--source-space":
                guard let value = nextValue(argument) else { return 2 }
                guard let parsed = TextureColorSpace(rawValue: value) else {
                    printError("error: --source-space must be one of: \(TextureColorSpace.allCases.map(\.rawValue).joined(separator: ", "))")
                    return 2
                }
                sourceSpace = parsed
            case "--target-space":
                guard let value = nextValue(argument) else { return 2 }
                guard let parsed = TextureColorSpace(rawValue: value) else {
                    printError("error: --target-space must be one of: \(TextureColorSpace.allCases.map(\.rawValue).joined(separator: ", "))")
                    return 2
                }
                targetSpace = parsed
            case "--lightness-bias":
                guard let value = nextValue(argument), let parsed = Double(value) else {
                    printError("error: --lightness-bias needs a number")
                    return 2
                }
                lightnessBias = parsed
            case "--chroma-preservation":
                guard let value = nextValue(argument), let parsed = Double(value) else {
                    printError("error: --chroma-preservation needs a number")
                    return 2
                }
                chromaPreservation = parsed
            case "--preserve-hue-variation":
                preserveHueVariation = true
            case "--mask-uv":
                guard let value = nextValue(argument) else { return 2 }
                let parts = value.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else {
                    printError("error: --mask-uv needs u,v (e.g. 0.5,0.5)")
                    return 2
                }
                maskUV = (parts[0], parts[1])
            case "--mask-threshold":
                guard let value = nextValue(argument), let parsed = Double(value) else {
                    printError("error: --mask-threshold needs a number")
                    return 2
                }
                maskThreshold = parsed
            case "--prim":
                guard let value = nextValue(argument) else { return 2 }
                prim = value
            case "--json":
                json = true
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)\n" + CLIRunner.usage)
                    return 2
                }
                positional.append(argument)
            }
            index += 1
        }

        // The in-USDZ prim path is not authorable yet (Phase 7 texture networks).
        if prim != nil {
            printError("error: --prim (recolor a part inside a .usdz) needs UsdUVTexture-network authoring, which is not implemented yet (ROADMAP Phase 7). Recolor a standalone texture image instead.")
            return 2
        }
        guard positional.count == 2 else {
            printError("error: recolor needs an input and output image\n" + CLIRunner.usage)
            return 2
        }
        guard let colorText = color else {
            printError("error: recolor needs --color '#RRGGBB'\n" + CLIRunner.usage)
            return 2
        }
        let target: (r: Double, g: Double, b: Double)
        do {
            target = try RecolorPipeline.target(fromHex: colorText)
        } catch {
            printError("error: invalid --color '\(colorText)' (expected #RRGGBB)")
            return 2
        }

        let inputURL = URL(fileURLWithPath: positional[0])
        let outputURL = URL(fileURLWithPath: positional[1])
        let sourceData: Data
        do {
            sourceData = try readFile(inputURL)
        } catch {
            printError("error: cannot read \(inputURL.path): \(error.localizedDescription)")
            return 1
        }

        do {
            let image = try RGBAImageCodec.decode(sourceData)
            var mask: RecolorMask?
            if let uv = maskUV {
                mask = RecolorSegmenter().similarityMask(
                    image, colorSpace: sourceSpace, atUV: uv, threshold: maskThreshold)
            }
            let request = RecolorRequest(
                target: target, targetSpace: targetSpace, sourceSpace: sourceSpace,
                mode: mode, lightnessBias: lightnessBias,
                chromaPreservation: chromaPreservation,
                preserveHueVariation: preserveHueVariation, mask: mask)
            let result = try RecolorPipeline.recolor(image, request: request)
            let encoded = try RGBAImageCodec.encodePNG(result.image)
            try writeFile(encoded, outputURL)
            if json {
                let report = Report(
                    output: outputURL.path, width: image.width, height: image.height,
                    mode: mode.rawValue, achievedDeltaE: result.achievedDeltaE)
                output(try report.jsonString())
            } else {
                output("recolored \(inputURL.lastPathComponent) → \(outputURL.lastPathComponent) (ΔE \(String(format: "%.2f", result.achievedDeltaE)))")
            }
            return 0
        } catch {
            printError("error: recolor failed: \(error.localizedDescription)")
            return 1
        }
    }

    struct Report: Codable {
        var output: String
        var width: Int
        var height: Int
        var mode: String
        var achievedDeltaE: Double

        func jsonString() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}
