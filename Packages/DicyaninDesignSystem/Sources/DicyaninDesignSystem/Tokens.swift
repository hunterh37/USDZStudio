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

/// The blue-graphite dark-theme palette (specs/design-system.md —
/// enterprise-restrained, no gradients-for-decoration). Every neutral carries a
/// cool ~220° cast so chrome reads as one material. Light theme lands in Phase 5.
public enum Palette {
    // Surfaces, darkest → lightest.
    public static let viewportBackground = ColorToken(hex: "#0D0F13")!
    public static let windowBackground = ColorToken(hex: "#14161C")!
    public static let panelBackground = ColorToken(hex: "#1A1D24")!
    /// Toolbars, cards, and other raised chrome sit one step above panels.
    public static let surfaceElevated = ColorToken(hex: "#20242D")!
    /// Text fields, wells, and code areas sit one step below panels.
    public static let surfaceSunken = ColorToken(hex: "#111318")!
    /// Pointer-hover wash for rows and buttons.
    public static let surfaceHover = ColorToken(hex: "#262B35")!

    // Lines.
    public static let panelBorder = ColorToken(hex: "#2B303B")!
    /// Subtler inner hairline for nested cards and section rules.
    public static let borderSubtle = ColorToken(hex: "#222630")!

    // Text.
    public static let textPrimary = ColorToken(hex: "#E7EAF0")!
    public static let textSecondary = ColorToken(hex: "#8C94A6")!
    /// Placeholder / disabled text.
    public static let textTertiary = ColorToken(hex: "#5B6373")!

    // Semantics.
    public static let accent = ColorToken(hex: "#5B9DFF")!

    // Axis tints (Blender-idiom X/Y/Z gizmo colors, tuned to the graphite cast).
    public static let axisX = ColorToken(hex: "#EF5E5E")!
    public static let axisY = ColorToken(hex: "#67C46E")!
    public static let axisZ = ColorToken(hex: "#559BE6")!
    public static let success = ColorToken(hex: "#3ECF8E")!
    public static let warning = ColorToken(hex: "#E8B341")!
    public static let error = ColorToken(hex: "#F0564A")!
}

/// Corner-radius tokens so components round consistently.
public enum Radius {
    /// Chips, badges, small controls.
    public static let sm: Double = 4
    /// Buttons, rows, fields.
    public static let md: Double = 6
    /// Cards and panels.
    public static let lg: Double = 10
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
