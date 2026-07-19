import Testing
import Foundation
@testable import openusdz

@Suite("thumbnail subcommand")
struct ThumbnailCommandTests {

    private final class Capture: @unchecked Sendable {
        var err: [String] = []
    }

    /// Pure resolution against a fake filesystem/interpreter — no spawning.
    private func resolve(
        _ arguments: [String],
        python: String? = "/venv/bin/python3",
        existing: Set<String> = ["/models/fox.usda", "/venv/bin/python3", "/venv/bin/usdrecord"],
        environment: [String: String] = [:]
    ) -> (ThumbnailCommand.Resolution, Capture) {
        let capture = Capture()
        let resolution = ThumbnailCommand.resolve(
            arguments: arguments,
            locatePython: { python },
            fileExists: { existing.contains($0) },
            environment: environment,
            printError: { capture.err.append($0) })
        return (resolution, capture)
    }

    @Test func singleFrameInvokesUsdrecordDirectly() throws {
        let (resolution, _) = resolve(["/models/fox.usda", "-o", "/tmp/fox.png", "--size", "256"])
        guard case .invocation(let invocation) = resolution else {
            Issue.record("expected invocation, got \(resolution)"); return
        }
        #expect(invocation.usdrecord == "/venv/bin/usdrecord")
        #expect(invocation.arguments == ["--imageWidth", "256", "/models/fox.usda", "/tmp/fox.png"])
        #expect(invocation.wrapper == nil)
    }

    @Test func defaultOutputIsModelNamePNGAtSize512() throws {
        let (resolution, _) = resolve(["/models/fox.usda"])
        guard case .invocation(let invocation) = resolution else {
            Issue.record("expected invocation"); return
        }
        #expect(invocation.arguments == ["--imageWidth", "512", "/models/fox.usda", "fox.png"])
    }

    @Test func turntableAuthorsARotatingWrapperStage() throws {
        let (resolution, _) = resolve(
            ["/models/fox.usda", "-o", "/tmp/turn.###.png", "--frames", "8"])
        guard case .invocation(let invocation) = resolution else {
            Issue.record("expected invocation"); return
        }
        let wrapper = try #require(invocation.wrapper)
        #expect(wrapper.path == "/models/.fox.turntable.usda")
        #expect(invocation.arguments == ["--imageWidth", "512", "--frames", "1:8",
                                         wrapper.path, "/tmp/turn.###.png"])
        // Wrapper: references the model and spins a full turn, ending one
        // step short of 360 so frame N isn't a duplicate of frame 1.
        #expect(wrapper.contents.contains("references = @/models/fox.usda@"))
        #expect(wrapper.contents.contains("endTimeCode = 8"))
        #expect(wrapper.contents.contains("1: 0"))
        #expect(wrapper.contents.contains("8: 315"))
        #expect(wrapper.contents.contains("xformOp:rotateY"))
    }

    @Test func turntableRequiresAFramePlaceholder() {
        let (resolution, capture) = resolve(["/models/fox.usda", "-o", "/tmp/turn.png", "--frames", "8"])
        #expect(resolution == .fail(2))
        #expect(capture.err.contains { $0.contains("placeholder") })
    }

    @Test func usdrecordEnvOverrideWins() throws {
        let (resolution, _) = resolve(
            ["/models/fox.usda"],
            existing: ["/models/fox.usda", "/venv/bin/python3", "/opt/usdrecord"],
            environment: ["DICYANIN_USDRECORD": "/opt/usdrecord"])
        guard case .invocation(let invocation) = resolution else {
            Issue.record("expected invocation"); return
        }
        #expect(invocation.usdrecord == "/opt/usdrecord")
    }

    @Test func missingUsdrecordFailsWithGuidance() {
        let (resolution, capture) = resolve(
            ["/models/fox.usda"],
            existing: ["/models/fox.usda", "/venv/bin/python3"]) // no usdrecord
        #expect(resolution == .fail(1))
        #expect(capture.err.contains { $0.contains("usdrecord not found") })
    }

    @Test func missingPythonAlsoFails() {
        let (resolution, _) = resolve(["/models/fox.usda"], python: nil,
                                      existing: ["/models/fox.usda"])
        #expect(resolution == .fail(1))
    }

    @Test func usageErrors() {
        #expect(resolve([]).0 == .fail(2))                                        // no model
        #expect(resolve(["/models/fox.usda", "extra.usda"]).0 == .fail(2))        // two models
        #expect(resolve(["/models/fox.obj"]).0 == .fail(2))                       // wrong type
        #expect(resolve(["/models/fox.usda", "--size", "0"]).0 == .fail(2))       // bad size
        #expect(resolve(["/models/fox.usda", "--frames", "999"]).0 == .fail(2))   // bad frames
        #expect(resolve(["/models/fox.usda", "--wat"]).0 == .fail(2))             // unknown flag
        #expect(resolve(["/models/missing.usda"]).0 == .fail(1))                  // no such file
    }

    @Test func runSpawnsAndReportsTheOutput() {
        // End-to-end through run() with a stubbed spawn: exit code passthrough.
        var spawned: [ThumbnailCommand.Invocation] = []
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UUID().uuidString).usda")
        try? Data("#usda 1.0\n".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Force resolution failure cleanly when no usdrecord exists on this
        // machine — the interesting spawn path is covered via resolve() tests;
        // here we only check run() maps a failed resolution to its exit code.
        let code = ThumbnailCommand.run(
            arguments: [temp.path],
            print: { _ in },
            printError: { _ in },
            spawn: { spawned.append($0); return 0 })
        if code == 0 {
            #expect(spawned.count == 1) // machine has a runtime: spawn happened
        } else {
            #expect(spawned.isEmpty && code == 1) // no runtime: fail(1), no spawn
        }
    }
}

/// Drives `run()` through its spawn + `finish` branches deterministically.
/// `run()` locates `usdrecord` via the process environment (not injectable),
/// so these force resolution with `DICYANIN_USDRECORD` and a real temp file,
/// then inject `spawn` to exercise the wrapper-write, success, and failure
/// paths without launching a real subprocess. Serialized because it mutates
/// the process environment.
@Suite("thumbnail run() spawn paths", .serialized)
struct ThumbnailRunTests {

    private final class Box: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
        var spawned: [ThumbnailCommand.Invocation] = []
        var wrapperExistedAtSpawn = false
    }

    /// A fresh temp dir containing a real `.usda` model and a fake `usdrecord`
    /// pointed at by `DICYANIN_USDRECORD`, so `resolve()` yields an invocation.
    private func withFixture(_ body: (URL, Box) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let usdrecord = dir.appendingPathComponent("usdrecord")
        try Data("#!/bin/sh\n".utf8).write(to: usdrecord)
        setenv("DICYANIN_USDRECORD", usdrecord.path, 1)
        defer { unsetenv("DICYANIN_USDRECORD") }
        try body(dir, Box())
    }

    @Test func singleFrameSpawnsAndReportsTheOutput() throws {
        try withFixture { dir, box in
            let model = dir.appendingPathComponent("fox.usda")
            try Data("#usda 1.0\n".utf8).write(to: model)
            let out = dir.appendingPathComponent("fox.png").path
            let code = ThumbnailCommand.run(
                arguments: [model.path, "-o", out],
                print: { box.out.append($0) },
                printError: { box.err.append($0) },
                spawn: { box.spawned.append($0); return 0 })
            #expect(code == 0)
            #expect(box.spawned.count == 1)
            #expect(box.spawned.first?.wrapper == nil)
            #expect(box.out.contains { $0.hasPrefix("wrote ") && $0.hasSuffix(out) })
            #expect(box.err.isEmpty)
        }
    }

    @Test func nonZeroSpawnStatusReportsError() throws {
        try withFixture { dir, box in
            let model = dir.appendingPathComponent("fox.usda")
            try Data("#usda 1.0\n".utf8).write(to: model)
            let code = ThumbnailCommand.run(
                arguments: [model.path],
                print: { box.out.append($0) },
                printError: { box.err.append($0) },
                spawn: { box.spawned.append($0); return 3 })
            #expect(code == 1)
            #expect(box.spawned.count == 1)
            #expect(box.err.contains { $0.contains("status 3") })
        }
    }

    @Test func turntableWritesWrapperBeforeSpawningThenCleansUp() throws {
        try withFixture { dir, box in
            let model = dir.appendingPathComponent("fox.usda")
            try Data("#usda 1.0\n".utf8).write(to: model)
            let wrapperPath = dir.appendingPathComponent(".fox.turntable.usda").path
            let code = ThumbnailCommand.run(
                arguments: [model.path, "-o", dir.appendingPathComponent("turn.###.png").path,
                            "--frames", "4"],
                print: { box.out.append($0) },
                printError: { box.err.append($0) },
                spawn: {
                    box.spawned.append($0)
                    box.wrapperExistedAtSpawn =
                        FileManager.default.fileExists(atPath: $0.wrapper?.path ?? "")
                    return 0
                })
            #expect(code == 0)
            #expect(box.spawned.count == 1)
            #expect(box.wrapperExistedAtSpawn)                                   // written before spawn
            #expect(!FileManager.default.fileExists(atPath: wrapperPath))        // removed after
        }
    }

    @Test func turntableWrapperWriteFailureReturnsOne() throws {
        try withFixture { dir, box in
            let model = dir.appendingPathComponent("fox.usda")
            try Data("#usda 1.0\n".utf8).write(to: model)
            // Occupy the wrapper path with a directory so writing the stage throws.
            let wrapperPath = dir.appendingPathComponent(".fox.turntable.usda")
            try FileManager.default.createDirectory(at: wrapperPath, withIntermediateDirectories: true)
            let code = ThumbnailCommand.run(
                arguments: [model.path, "-o", dir.appendingPathComponent("turn.###.png").path,
                            "--frames", "4"],
                print: { box.out.append($0) },
                printError: { box.err.append($0) },
                spawn: { box.spawned.append($0); return 0 })
            #expect(code == 1)
            #expect(box.spawned.isEmpty)                                         // never reached spawn
            #expect(box.err.contains { $0.contains("could not write turntable stage") })
        }
    }
}
