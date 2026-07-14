import Foundation

/// Parsing and clamping logic behind inspector numeric fields
/// (transforms, exposure, metersPerUnit…). Pure logic → 100% coverable
/// (specs/testing.md: "numeric parsing, scrub math").
public enum NumericFieldParser {

    /// Parses user input tolerantly: trims whitespace, accepts `,` as a
    /// decimal separator, strips a trailing `°` or `%`, accepts leading `+`.
    /// Returns `nil` for anything that isn't a finite number.
    public static func parse(_ input: String) -> Double? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("°") || text.hasSuffix("%") { text.removeLast() }
        text = text.replacingOccurrences(of: ",", with: ".")
        // Double(_:) already accepts a single leading "+"; no manual stripping,
        // so malformed input like "++5" is rejected.
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// Clamps `value` into `range`.
    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Snaps `value` to the nearest multiple of `step` (no-op for step <= 0).
    public static func snap(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    /// Formats a value for field display: up to `maxFractionDigits` digits,
    /// trailing zeros trimmed, `-0` normalized to `0`.
    public static func format(_ value: Double, maxFractionDigits: Int = 3) -> String {
        let digits = max(0, maxFractionDigits)
        let power = pow(10.0, Double(digits))
        var rounded = (value * power).rounded() / power
        if rounded == 0 { rounded = 0 }  // normalize -0
        if rounded == rounded.rounded() && abs(rounded) < 1e15 {
            return String(Int(rounded))
        }
        var text = String(format: "%.\(digits)f", rounded)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Math for click-drag scrubbing on numeric fields.
public enum ScrubMath {

    /// Points of horizontal drag per step at normal sensitivity.
    public static let pointsPerStep: Double = 4

    /// Converts a drag delta (in points) into a value change.
    /// - Parameters:
    ///   - base: value when the drag began
    ///   - dragDelta: horizontal drag distance in points (negative = left)
    ///   - step: value change per scrub step (e.g. 0.01 for meters)
    ///   - fine: ⌥ held — 10× finer
    ///   - coarse: ⇧ held — 10× coarser (ignored when `fine` is set)
    public static func value(
        base: Double,
        dragDelta: Double,
        step: Double,
        fine: Bool = false,
        coarse: Bool = false
    ) -> Double {
        var effectiveStep = step
        if fine {
            effectiveStep /= 10
        } else if coarse {
            effectiveStep *= 10
        }
        let steps = (dragDelta / pointsPerStep).rounded(.towardZero)
        return base + steps * effectiveStep
    }
}
