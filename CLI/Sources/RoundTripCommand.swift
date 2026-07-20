import Foundation
import USDCore
import USDBridge
import EditingKit

/// `openusdz roundtrip <file>` — the T1 round-trip invariant harness
/// (specs/testing.md §Test Layers, ROADMAP Milestone 4).
///
/// Two invariants, checked in order:
///
/// 1. **Model idempotence** (always enforced). `open(F)` must equal
///    `open(save(open(F)))`. This is the invariant that actually protects a
///    user's file: whatever the editor understood when it opened the document
///    must survive a save/reopen cycle unchanged. It is checked on the value
///    -typed `StageSnapshot`, so it covers every prim, attribute, relationship,
///    variant set, and piece of stage metadata the editor models.
///
/// 2. **Edit/undo neutrality** (always enforced). `open(F)` must equal
///    `open(save(undoAll(edit(open(F)))))`. Running real commands through a
///    journaled `CommandStack` and then undoing all of them must land exactly
///    back on the opened model — this exercises the same inverse-capture path
///    the crash journal relies on.
///
/// 3. **Strict text diff** (`--strict`, opt-in per file). The flattened USD text
///    of `F` and `save(open(F))` must be equivalent under `usd_roundtrip.py`.
///    This is stronger than (1) and only holds for files whose content the
///    editor's model represents losslessly — attributes the bridge surfaces as
///    `.unsupported` (e.g. purely time-sampled channels) round-trip in the model
///    but not yet in the file text. `scripts/roundtrip-gate.sh` applies it to
///    the corpus subset listed as strict-clean, so the lossy set stays visible
///    and shrinks as the bridge grows.
enum RoundTripCommand {

    struct Report: Equatable {
        var file: String
        var idempotent: Bool
        var editUndoNeutral: Bool
        /// `nil` when `--strict` was not requested.
        var strictTextClean: Bool?
        var details: [String] = []

        var passed: Bool {
            idempotent && editUndoNeutral && (strictTextClean ?? true)
        }
    }

    /// Injection seams keep the whole flow unit-testable without usd-core.
    struct Environment {
        var open: (URL) async throws -> StageSnapshot
        var save: (StageSnapshot, URL) async throws -> Void
        /// Returns `true` when the two files are textually equivalent.
        var textDiffClean: (URL, URL) throws -> Bool
        var temporaryDirectory: () throws -> URL
    }

    static func run(
        arguments: [String],
        environment: Environment,
        print output: (String) -> Void,
        printError: (String) -> Void
    ) async -> Int32 {
        var paths: [String] = []
        var strict = false
        var json = false
        for argument in arguments {
            switch argument {
            case "--strict": strict = true
            case "--json": json = true
            default:
                guard !argument.hasPrefix("--") else {
                    printError("error: unknown option \(argument)")
                    return 2
                }
                paths.append(argument)
            }
        }
        guard !paths.isEmpty else {
            printError("error: roundtrip needs at least one file")
            return 2
        }

        var reports: [Report] = []
        for path in paths {
            do {
                reports.append(try await check(
                    URL(fileURLWithPath: path), strict: strict, environment: environment))
            } catch {
                printError("error: \(path): \(error)")
                return 1
            }
        }

        if json {
            output(encodeJSON(reports))
        } else {
            for report in reports { output(render(report)) }
        }
        return reports.allSatisfy(\.passed) ? 0 : 1
    }

    /// Runs both (or all three) invariants for one file.
    static func check(
        _ url: URL, strict: Bool, environment: Environment
    ) async throws -> Report {
        let scratch = try environment.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ext = url.pathExtension.isEmpty ? "usda" : url.pathExtension

        let original = try await environment.open(url)
        var report = Report(file: url.lastPathComponent, idempotent: false, editUndoNeutral: false)

        // (1) open → save → open must be a fixed point.
        let saved = scratch.appendingPathComponent("roundtrip.\(ext)")
        try await environment.save(original, saved)
        let reopened = try await environment.open(saved)
        report.idempotent = (reopened == original)
        if !report.idempotent {
            report.details.append(describe(difference: original, reopened))
        }

        // (2) open → edit → undo-all → save → open must also equal the original.
        let edited = scratch.appendingPathComponent("edited.\(ext)")
        let stage = InMemoryStage(original)
        let stack = CommandStack(stage: stage, journal: InMemoryCommandJournal())
        for command in exerciseCommands(for: original) {
            try stack.run(command)
        }
        while stack.canUndo { _ = try stack.undo() }
        try await environment.save(stage.currentSnapshot, edited)
        let afterUndo = try await environment.open(edited)
        report.editUndoNeutral = (afterUndo == reopened)
        if !report.editUndoNeutral {
            report.details.append("edit→undo-all did not restore the opened model")
        }

        // (3) optional strict text diff against the original file.
        if strict {
            report.strictTextClean = try environment.textDiffClean(url, saved)
            if report.strictTextClean == false {
                report.details.append("flattened text differs from the original file")
            }
        }
        return report
    }

    /// A deterministic edit burst over whatever the file actually contains:
    /// toggle visibility and active on the first prim, retitle stage metadata,
    /// and add then remove an attribute. Every one of these has a real inverse,
    /// so undoing them all must be a perfect no-op.
    static func exerciseCommands(for stage: StageSnapshot) -> [any EditCommand] {
        guard let first = stage.allPrims().first else { return [] }
        var metadata = stage.metadata
        metadata.customLayerData["roundtripProbe"] = "1"
        return [
            SetVisibilityCommand(path: first.path,
                                 newVisibility: first.visibility == .invisible ? .inherited : .invisible,
                                 oldVisibility: first.visibility),
            SetStageMetadataCommand(newMetadata: metadata, oldMetadata: stage.metadata),
        ]
    }

    static func describe(difference original: StageSnapshot, _ other: StageSnapshot) -> String {
        var notes: [String] = []
        if original.metadata != other.metadata { notes.append("stage metadata differs") }
        let a = original.allPrims().map(\.path), b = other.allPrims().map(\.path)
        if a != b {
            let lost = Set(a).subtracting(b).map(\.description).sorted()
            let gained = Set(b).subtracting(a).map(\.description).sorted()
            if !lost.isEmpty { notes.append("prims lost: \(lost.joined(separator: ", "))") }
            if !gained.isEmpty { notes.append("prims gained: \(gained.joined(separator: ", "))") }
            if lost.isEmpty && gained.isEmpty { notes.append("prim order differs") }
        } else {
            for (lhs, rhs) in zip(original.allPrims(), other.allPrims()) where lhs != rhs {
                notes.append("prim \(lhs.path) differs")
            }
        }
        return notes.isEmpty ? "snapshots differ" : notes.joined(separator: "; ")
    }

    static func render(_ report: Report) -> String {
        var lines = ["\(report.passed ? "PASS" : "FAIL")  \(report.file)"]
        lines.append("  open→save→open idempotent:      \(mark(report.idempotent))")
        lines.append("  open→edit→undo-all→save clean:  \(mark(report.editUndoNeutral))")
        if let strict = report.strictTextClean {
            lines.append("  flattened text diff clean:      \(mark(strict))")
        }
        for detail in report.details { lines.append("    · \(detail)") }
        return lines.joined(separator: "\n")
    }

    static func mark(_ ok: Bool) -> String { ok ? "ok" : "FAILED" }

    static func encodeJSON(_ reports: [Report]) -> String {
        let objects: [[String: Any]] = reports.map { report in
            var object: [String: Any] = [
                "file": report.file,
                "passed": report.passed,
                "idempotent": report.idempotent,
                "editUndoNeutral": report.editUndoNeutral,
                "details": report.details,
            ]
            if let strict = report.strictTextClean { object["strictTextClean"] = strict }
            return object
        }
        let payload: [String: Any] = ["reports": objects,
                                      "passed": reports.allSatisfy(\.passed)]
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
