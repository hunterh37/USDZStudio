import Foundation

/// A determinate progress tick emitted by a running script.
///
/// `_harness.py`'s `app.progress(fraction, message)` writes lines shaped like
/// `"[ 50%] Decimating…"` to stderr. This is the Swift-side parse of that
/// contract — the channel that turns the indeterminate import spinner into a
/// real progress bar while a script runs.
public struct ScriptProgress: Equatable, Sendable {

    /// Clamped to `0...1`.
    public let fraction: Double
    public let message: String

    public init(fraction: Double, message: String) {
        self.fraction = min(1, max(0, fraction))
        self.message = message
    }

    /// Parses one stderr line, returning a progress tick when the line matches
    /// the harness's `[NN%] message` format, else `nil` (an ordinary log line).
    public static func parse(line: String) -> ScriptProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "[" else { return nil }
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        let inside = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard inside.hasSuffix("%") else { return nil }
        let number = inside.dropLast().trimmingCharacters(in: .whitespaces)
        guard let percent = Int(number) else { return nil }
        let message = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        return ScriptProgress(fraction: Double(percent) / 100.0, message: message)
    }
}

/// A single event surfaced while a script runs, ordered as emitted.
public enum ScriptRunEvent: Equatable, Sendable {
    /// A determinate progress tick (`app.progress`).
    case progress(ScriptProgress)
    /// Any other line the script wrote to stderr (`app.log`, tracebacks, …).
    case log(String)

    /// Classifies a raw stderr line into the appropriate event.
    public static func classify(line: String) -> ScriptRunEvent {
        if let progress = ScriptProgress.parse(line: line) {
            return .progress(progress)
        }
        return .log(line)
    }
}
