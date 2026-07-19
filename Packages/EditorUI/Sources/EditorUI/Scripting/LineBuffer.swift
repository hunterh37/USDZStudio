import Foundation

/// Splits a byte stream arriving in arbitrary chunks into whole newline-
/// terminated lines. A script's stderr (where `app.progress`/`app.log` write)
/// arrives in pipe-sized reads that don't respect line boundaries, so we buffer
/// the tail until the next newline before emitting.
///
/// Pure and synchronous so the line-boundary logic is unit-testable without a
/// live process.
struct LineBuffer {

    private var pending = ""

    /// Appends `text` and returns every complete line it now contains, keeping
    /// any trailing partial line buffered for the next append.
    mutating func append(_ text: String) -> [String] {
        pending += text
        guard pending.contains("\n") else { return [] }
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()   // trailing partial (empty if text ended in \n)
        return lines
    }

    /// Flushes any buffered partial line at end-of-stream (empty when the
    /// stream ended on a newline).
    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = "" }
        return pending
    }
}
