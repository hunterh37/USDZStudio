import Foundation
import USDCore
import USDBridge

/// `openusdz diff <before> <after> [--json]` — the structural stage diff
/// (ROADMAP §Continuous — *USD stage diff view*). Opens two stages through the
/// bridge and reports what changed, prim-by-prim, in `StageDiff` terms.
///
/// Exit codes follow `diff(1)` so the command composes in shell pipelines:
/// `0` when the two stages are structurally identical, `1` when they differ,
/// and `2` for a usage error or a file that could not be opened ("trouble").
enum DiffCommand {

    static func run(
        arguments: [String],
        openStage: (URL) async throws -> any USDStageProtocol,
        print output: (String) -> Void,
        printError: (String) -> Void
    ) async -> Int32 {
        var positional: [String] = []
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                guard !argument.hasPrefix("--") else {
                    printError("error: unknown option \(argument)")
                    return 2
                }
                positional.append(argument)
            }
        }
        guard positional.count == 2 else {
            printError("error: diff needs exactly two files (before, after)")
            return 2
        }

        let before: any USDStageProtocol
        let after: any USDStageProtocol
        do {
            before = try await openStage(URL(fileURLWithPath: positional[0]))
            after = try await openStage(URL(fileURLWithPath: positional[1]))
        } catch {
            let bridgeError = error as? BridgeError
            printError("error: \(bridgeError?.errorDescription ?? error.localizedDescription)")
            if let suggestion = bridgeError?.recoverySuggestion {
                printError(suggestion)
            }
            return 2
        }

        let diff = StageDiff.between(before, after)
        if json {
            output(encodeJSON(diff, before: positional[0], after: positional[1]))
        } else {
            output(diff.render())
        }
        return diff.isEmpty ? 0 : 1
    }

    /// Machine-readable diff: the full `StageDiff` plus the two file names and an
    /// `identical` flag mirroring the exit code.
    static func encodeJSON(_ diff: StageDiff, before: String, after: String) -> String {
        struct Payload: Encodable {
            var before: String
            var after: String
            var identical: Bool
            var diff: StageDiff
        }
        let payload = Payload(before: before, after: after, identical: diff.isEmpty, diff: diff)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
