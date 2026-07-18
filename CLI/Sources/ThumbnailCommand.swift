import Foundation
import USDBridge

/// `dicyanin-usdz thumbnail <file> [-o out.png] [--size N] [--frames N]` —
/// the agent modeling loop's *observe* step. Single frame renders the model
/// as-is; `--frames N` authors a turntable wrapper stage (animated rotateY
/// around a reference to the model) and renders N frames via `usdrecord`,
/// which auto-frames the stage bounds — no camera math needed.
enum ThumbnailCommand {

    struct Invocation: Equatable {
        var usdrecord: String
        var arguments: [String]
        /// Turntable wrapper stage to write before spawning, if any.
        var wrapper: (path: String, contents: String)?

        static func == (l: Invocation, r: Invocation) -> Bool {
            l.usdrecord == r.usdrecord && l.arguments == r.arguments
                && l.wrapper?.path == r.wrapper?.path
                && l.wrapper?.contents == r.wrapper?.contents
        }
    }

    enum Resolution: Equatable {
        case invocation(Invocation)
        case fail(Int32)
    }

    /// Pure, testable resolution: parses flags, locates `usdrecord` (env
    /// override → next to the Python interpreter), and, for turntables,
    /// synthesizes the wrapper stage text. Does not touch the filesystem.
    static func resolve(
        arguments: [String],
        locatePython: () -> String?,
        fileExists: (String) -> Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        printError: (String) -> Void
    ) -> Resolution {
        var positional: [String] = []
        var outPath: String?
        var size = 512
        var frames = 1
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--out":
                guard index + 1 < arguments.count else {
                    printError("error: \(argument) needs a file path")
                    return .fail(2)
                }
                outPath = arguments[index + 1]
                index += 2
            case "--size":
                guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]),
                      parsed > 0 else {
                    printError("error: --size needs a positive integer")
                    return .fail(2)
                }
                size = parsed
                index += 2
            case "--frames":
                guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]),
                      (1...360).contains(parsed) else {
                    printError("error: --frames needs an integer in 1…360")
                    return .fail(2)
                }
                frames = parsed
                index += 2
            default:
                if argument.hasPrefix("-") {
                    printError("error: unknown option \(argument)\n" + CLIRunner.usage)
                    return .fail(2)
                }
                positional.append(argument)
                index += 1
            }
        }
        guard positional.count == 1 else {
            printError("error: thumbnail needs exactly one model file\n" + CLIRunner.usage)
            return .fail(2)
        }
        let model = URL(fileURLWithPath: positional[0]).standardizedFileURL
        guard ["usd", "usda", "usdc", "usdz"].contains(model.pathExtension.lowercased()) else {
            printError("error: thumbnail needs a .usd/.usda/.usdc/.usdz file")
            return .fail(2)
        }
        guard fileExists(model.path) else {
            printError("error: no such file \(model.path)")
            return .fail(1)
        }

        guard let usdrecord = locateUsdrecord(environment: environment,
                                              locatePython: locatePython,
                                              fileExists: fileExists) else {
            printError("error: usdrecord not found — run scripts/fetch-python-runtime.sh or set DICYANIN_USDRECORD")
            return .fail(1)
        }

        let output = outPath ?? model.deletingPathExtension().lastPathComponent + ".png"
        if frames == 1 {
            return .invocation(Invocation(
                usdrecord: usdrecord,
                arguments: ["--imageWidth", String(size), model.path, output],
                wrapper: nil))
        }

        // Turntable: usdrecord's `#`-pattern output writes one image per frame.
        guard output.contains("#") else {
            printError("error: with --frames, the output must contain a frame placeholder, e.g. turn.###.png")
            return .fail(2)
        }
        let wrapperPath = model.deletingLastPathComponent()
            .appendingPathComponent(".\(model.deletingPathExtension().lastPathComponent).turntable.usda").path
        return .invocation(Invocation(
            usdrecord: usdrecord,
            arguments: ["--imageWidth", String(size), "--frames", "1:\(frames)",
                        wrapperPath, output],
            wrapper: (wrapperPath, turntableStage(modelPath: model.path, frames: frames))))
    }

    /// `DICYANIN_USDRECORD` override, else `usdrecord` beside the located
    /// Python interpreter (the venv layout `fetch-python-runtime.sh` creates).
    static func locateUsdrecord(
        environment: [String: String],
        locatePython: () -> String?,
        fileExists: (String) -> Bool
    ) -> String? {
        if let override = environment["DICYANIN_USDRECORD"], !override.isEmpty {
            return fileExists(override) ? override : nil
        }
        guard let python = locatePython() else { return nil }
        let candidate = URL(fileURLWithPath: python).deletingLastPathComponent()
            .appendingPathComponent("usdrecord").path
        return fileExists(candidate) ? candidate : nil
    }

    /// Wrapper stage: the model referenced under an Xform whose rotateY is
    /// animated one full turn across the frame range. usdrecord's default
    /// camera auto-frames the stage, so this works without knowing bounds.
    static func turntableStage(modelPath: String, frames: Int) -> String {
        let lastAngle = 360.0 * Double(frames - 1) / Double(frames)
        return """
        #usda 1.0
        (
            defaultPrim = "Turntable"
            startTimeCode = 1
            endTimeCode = \(frames)
            timeCodesPerSecond = 24
        )

        def Xform "Turntable"
        {
            float xformOp:rotateY.timeSamples = {
                1: 0,
                \(frames): \(lastAngle),
            }
            uniform token[] xformOpOrder = ["xformOp:rotateY"]

            def "Model" (
                prepend references = @\(modelPath)@
            )
            {
            }
        }
        """
    }

    static func run(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void,
        spawn: (Invocation) -> Int32 = defaultSpawn
    ) -> Int32 {
        let locator = PythonRuntimeLocator()
        let resolution = resolve(
            arguments: arguments,
            locatePython: { locator.locate() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            printError: printError)
        switch resolution {
        case .fail(let code):
            return code
        case .invocation(let invocation):
            if let wrapper = invocation.wrapper {
                do {
                    try Data(wrapper.contents.utf8)
                        .write(to: URL(fileURLWithPath: wrapper.path))
                } catch {
                    printError("error: could not write turntable stage: \(error)")
                    return 1
                }
                defer { try? FileManager.default.removeItem(atPath: wrapper.path) }
                return finish(spawn(invocation), invocation, print: output, printError: printError)
            }
            return finish(spawn(invocation), invocation, print: output, printError: printError)
        }
    }

    private static func finish(_ status: Int32, _ invocation: Invocation,
                               print output: (String) -> Void,
                               printError: (String) -> Void) -> Int32 {
        if status == 0 {
            output("wrote \(invocation.arguments.last!)")
            return 0
        }
        printError("error: usdrecord exited with status \(status)")
        return 1
    }

    static func defaultSpawn(_ invocation: Invocation) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.usdrecord)
        process.arguments = invocation.arguments
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                Data("error: could not launch \(invocation.usdrecord): \(error)\n".utf8))
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
