import Foundation

/// Spacing tokens on the 4pt grid (specs/design-system.md).
public enum Spacing {
    /// The base grid unit: 4pt.
    public static let unit: Double = 4

    /// Returns `units` grid steps in points. Negative units are clamped to 0.
    public static func grid(_ units: Int) -> Double {
        Double(max(0, units)) * unit
    }

    public static let xxs = grid(1)   // 4
    public static let xs = grid(2)    // 8
    public static let sm = grid(3)    // 12
    public static let md = grid(4)    // 16
    public static let lg = grid(6)    // 24
    public static let xl = grid(8)    // 32

    /// Snaps an arbitrary dimension to the nearest grid step (min 0).
    public static func snapped(_ value: Double) -> Double {
        max(0, (value / unit).rounded() * unit)
    }
}

/// A framework-agnostic sRGB color token. UI layers map this to
/// SwiftUI `Color` / `NSColor`; keeping the token pure keeps it unit-testable.
public struct ColorToken: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (leading `#` optional, case-insensitive).
    public init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else { return nil }
        if cleaned.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255)
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255)
        }
    }

    /// Uppercase `#RRGGBB` (alpha 1) or `#RRGGBBAA` form.
    public var hexString: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha == 1 ? rgb : rgb + byte(alpha)
    }
}

/// The neutral dark-theme palette (specs/design-system.md — enterprise-restrained,
/// no gradients-for-decoration). Light theme lands in Phase 5.
public enum Palette {
    public static let windowBackground = ColorToken(hex: "#1E1F22")!
    public static let panelBackground = ColorToken(hex: "#26272B")!
    public static let panelBorder = ColorToken(hex: "#3A3B40")!
    public static let textPrimary = ColorToken(hex: "#E8E8EA")!
    public static let textSecondary = ColorToken(hex: "#9A9BA1")!
    public static let accent = ColorToken(hex: "#4C8DFF")!
    public static let warning = ColorToken(hex: "#E5A50A")!
    public static let error = ColorToken(hex: "#E0453A")!
    public static let viewportBackground = ColorToken(hex: "#141519")!
}

/// Typography scale (SF Pro via system fonts; sizes only — pure and testable).
public enum TypeScale {
    public static let caption: Double = 10
    public static let body: Double = 12
    public static let label: Double = 11
    public static let heading: Double = 13
    public static let title: Double = 15

    /// Monospaced-digit inspector fields use `body` size.
    public static let inspectorField = body
}
