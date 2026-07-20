import Foundation

/// The interactive Python **console** (REPL) layer — the counterpart to
/// `ScriptRunner`'s one-shot script runs (specs/validation.md — Python console,
/// ROADMAP Milestone 5).
///
/// Everything here is pure orchestration: buffering multi-line input, recalling
/// history, building the injected program text, and coalescing one submission
/// into exactly one interpreter run (the "single-undo script run" contract —
/// the app records each completed submission as a single undoable command). All
/// process I/O is delegated to a `ScriptExecuting`, so the whole console is
/// exercised end-to-end in unit tests against an in-memory fake, no Python.

/// What the console injects into a submission's namespace: the document under
/// edit and the current selection. `ReplProgram` turns this into runnable
/// Python that binds `stage`, `selection`, and `app`.
public struct ReplContext: Equatable, Sendable {
    /// The USD/USDZ file the console operates on — opened as the live `stage`.
    public var inputPath: String
    /// Selected prim paths, exposed as the `selection` list.
    public var selection: [String]

    public init(inputPath: String, selection: [String] = []) {
        self.inputPath = inputPath
        self.selection = selection
    }
}

/// A single completed console interaction: the source submitted plus what the
/// interpreter wrote back. Appended to the session transcript in order.
public struct ReplEntry: Equatable, Sendable {
    public let input: String
    /// Captured stdout (`print(...)`, `app.log(...)`).
    public let output: String
    /// Captured stderr — a traceback when the submission raised.
    public let diagnostics: String
    /// Whether the interpreter exited non-zero (the submission raised).
    public let isError: Bool

    public init(input: String, output: String, diagnostics: String, isError: Bool) {
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        self.isError = isError
    }
}

/// Turns a user submission plus a `ReplContext` into a self-contained Python
/// program that binds the injected names and then runs the user's code. The
/// program is deliberately whole-file (not a persistent interpreter): each
/// submission is one process run, which is what makes it one undoable unit.
public enum ReplProgram {

    /// Marks the generated preamble so a test — and a human reading a temp file —
    /// can tell console-authored source from a user's own script.
    public static let injectionBanner = "# --- OpenUSDZEditor console injection ---"
    public static let userCodeBanner = "# --- user code ---"

    /// Builds the runnable program. `stage` opens the document, `selection`
    /// resolves the injected prim paths, and `app` is a minimal console facade
    /// whose `log` goes to stdout and whose `select` rebinds `selection`.
    public static func source(userCode: String, context: ReplContext) -> String {
        """
        \(injectionBanner)
        from pxr import Usd, UsdGeom, Sdf
        stage = Usd.Stage.Open(\(pythonString(context.inputPath)))
        selection = [stage.GetPrimAtPath(p) for p in \(pythonList(context.selection))]

        class _ConsoleApp:
            def log(self, *parts):
                print(*parts)

            def select(self, paths):
                global selection
                selection = [stage.GetPrimAtPath(str(p)) for p in (paths or [])]

        app = _ConsoleApp()
        \(userCodeBanner)
        \(userCode)
        """
    }

    /// A Python string literal for `value`, escaping the characters that would
    /// otherwise break out of the quotes.
    static func pythonString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// A Python list literal of string literals.
    static func pythonList(_ items: [String]) -> String {
        "[" + items.map(pythonString).joined(separator: ", ") + "]"
    }
}

/// Decides whether a buffered submission is complete or still needs a
/// continuation line — the console's Return-vs-keep-typing rule.
public enum ReplInputClassifier {

    /// `true` when `buffer` is not yet a complete submission:
    /// - a trailing backslash (explicit line continuation);
    /// - unbalanced `()`, `[]`, or `{}` (brackets opened but not closed);
    /// - a compound statement (a logical line ending in `:`) whose block has
    ///   not been terminated by a trailing blank line.
    /// String contents are skipped when matching brackets and the trailing
    /// colon, so a `:` or `(` inside a quote never traps the console.
    public static func needsMoreInput(_ buffer: String) -> Bool {
        let scan = scanOutsideStrings(buffer)
        if scan.depth > 0 { return true }
        if scan.endsWithBackslash { return true }
        if scan.hasBlockHeader {
            // A compound statement (a line ending in `:`) completes on a blank
            // final line — the console's "press Return on an empty line" rule.
            let lines = buffer.components(separatedBy: "\n")
            let lastIsBlank = lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
            return !lastIsBlank
        }
        return false
    }

    private struct Scan {
        var depth: Int
        var hasBlockHeader: Bool
        var endsWithBackslash: Bool
    }

    /// Single pass that tracks bracket depth outside string literals and whether
    /// any logical line ends in a block-opening `:`.
    private static func scanOutsideStrings(_ buffer: String) -> Scan {
        var depth = 0
        var quote: Character?
        var escaped = false
        var lineLast: Character?
        var hasBlockHeader = false

        for character in buffer {
            if let active = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == active {
                    quote = nil
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
            case "(", "[", "{":
                depth += 1
                lineLast = character
            case ")", "]", "}":
                if depth > 0 { depth -= 1 }
                lineLast = character
            case "\n":
                if lineLast == ":" { hasBlockHeader = true }
                lineLast = nil
            case " ", "\t", "\r":
                break
            default:
                lineLast = character
            }
        }
        if lineLast == ":" { hasBlockHeader = true }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return Scan(depth: depth,
                    hasBlockHeader: hasBlockHeader,
                    endsWithBackslash: trimmed.hasSuffix("\\"))
    }
}

/// A recall ring for previously submitted sources (the Up/Down-arrow history of
/// any console). Duplicate-of-last and empty submissions are not recorded.
public struct ReplHistory: Equatable, Sendable {
    public private(set) var entries: [String] = []
    /// Navigation cursor: `entries.count` means "not currently browsing".
    private var cursor: Int = 0

    public init() {}

    /// Records a completed submission and resets browsing to the newest end.
    public mutating func record(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && entries.last != source {
            entries.append(source)
        }
        cursor = entries.count
    }

    /// Steps to an older entry (Up), or `nil` at the oldest / when empty.
    public mutating func previous() -> String? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Steps to a newer entry (Down); returns `nil` (and an empty draft) once
    /// past the newest entry.
    public mutating func next() -> String? {
        guard cursor < entries.count else { return nil }
        cursor += 1
        return cursor < entries.count ? entries[cursor] : nil
    }
}

/// The interactive console session. Buffers input until a submission is
/// complete, runs it as one interpreter process (one undoable unit), and keeps
/// an ordered transcript plus recall history.
public actor ReplSession {

    /// The result of feeding one line to the console.
    public enum Submission: Equatable, Sendable {
        /// The line was buffered; the submission needs a continuation line.
        case needsMore
        /// The submission completed and was evaluated.
        case evaluated(ReplEntry)
    }

    private let executor: any ScriptExecuting
    private let context: ReplContext
    private let writeProgram: @Sendable (String) -> URL

    private var buffer: [String] = []
    public private(set) var transcript: [ReplEntry] = []
    private var history = ReplHistory()

    public init(executor: any ScriptExecuting,
                context: ReplContext,
                writeProgram: @escaping @Sendable (String) -> URL = ReplSession.defaultProgramWriter) {
        self.executor = executor
        self.context = context
        self.writeProgram = writeProgram
    }

    /// The source buffered so far (for showing a continuation prompt).
    public func pendingSource() -> String { buffer.joined(separator: "\n") }

    /// Feeds one line to the console. Returns `.needsMore` while a multi-line
    /// submission is still open, or `.evaluated` once it runs.
    public func submit(line: String) async -> Submission {
        buffer.append(line)
        let joined = buffer.joined(separator: "\n")
        if ReplInputClassifier.needsMoreInput(joined) {
            return .needsMore
        }
        buffer.removeAll()
        history.record(joined)
        let entry = await evaluate(source: joined)
        transcript.append(entry)
        return .evaluated(entry)
    }

    /// Recall the previous history entry (Up arrow).
    public func recallPrevious() -> String? { history.previous() }
    /// Recall the next history entry (Down arrow).
    public func recallNext() -> String? { history.next() }

    private func evaluate(source: String) async -> ReplEntry {
        let program = ReplProgram.source(userCode: source, context: context)
        let url = writeProgram(program)
        do {
            let result = try await executor.execute(
                scriptPath: url.path, arguments: [], onStandardErrorLine: nil)
            return ReplEntry(input: source,
                             output: result.standardOutput,
                             diagnostics: result.standardError,
                             isError: !result.succeeded)
        } catch {
            return ReplEntry(input: source,
                             output: "",
                             diagnostics: String(describing: error),
                             isError: true)
        }
    }

    /// Writes a submission's program to a unique temp `.py` and returns its URL.
    public static let defaultProgramWriter: @Sendable (String) -> URL = { program in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicyanin-console-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("console.py")
        try? program.data(using: .utf8)?.write(to: url)
        return url
    }
}
