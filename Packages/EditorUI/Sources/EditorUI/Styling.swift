import SwiftUI
import USDCore
import DicyaninDesignSystem

/// SwiftUI bridges for the pure design-system tokens. Kept in one place so
/// every panel in EditorUI shares identical chrome (specs/design-system.md).
extension ColorToken {
    /// Maps a design-system token to SwiftUI.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// A small tinted tag — `uniform`, `anim`, `default` — used to annotate
/// inspector rows. Tint defaults to the accent but semantic colors work too.
struct Badge: View {
    let text: String
    let tint: ColorToken

    init(_ text: String, tint: ColorToken = Palette.accent) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(tint.color.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(tint.color.opacity(0.35), lineWidth: 1))
            .foregroundStyle(tint.color)
    }
}

/// The shared toolbar/action button: quiet by default, hover wash, accent tint
/// while its surface is active. One style so every bar in the app matches.
struct ToolbarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, isActive: isActive)
    }

    /// Inner view so hover state lives in a real `View`'s `@State`.
    private struct Inner: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: TypeScale.body, weight: .medium))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(background(pressed: configuration.isPressed)))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(isActive ? Palette.accent.color.opacity(0.4) : .clear,
                                      lineWidth: 1))
                .foregroundStyle(isActive ? Palette.accent.color : Palette.textPrimary.color)
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private func background(pressed: Bool) -> Color {
            if isActive { return Palette.accent.color.opacity(pressed ? 0.3 : 0.18) }
            if pressed { return Palette.surfaceHover.color.opacity(0.8) }
            return hovering ? Palette.surfaceHover.color : .clear
        }
    }
}

/// A raised card: elevated surface, hairline border, large radius. The basic
/// grouping container for panels, sheets, and drawers.
struct Card<Content: View>: View {
    var padding: Double = Spacing.sm
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Palette.surfaceElevated.color))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
    }
}

/// A panel's title strip: icon + uppercase label on the elevated surface with
/// a bottom hairline, plus optional trailing accessories.
struct PanelHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, systemImage: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: TypeScale.label, weight: .semibold))
                    .foregroundStyle(Palette.accent.color)
            }
            Text(title.uppercased())
                .font(.system(size: TypeScale.label, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.textSecondary.color)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Palette.surfaceElevated.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderSubtle.color).frame(height: 1)
        }
    }
}

/// A dot + monospaced label status pill for counts and states ("128 prims",
/// "3 issues"). Quietly graphite unless given a semantic tint.
struct StatusPill: View {
    let text: String
    var tint: ColorToken = Palette.textSecondary

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Circle().fill(tint.color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 2)
        .background(Capsule().fill(Palette.surfaceSunken.color))
        .overlay(Capsule().strokeBorder(Palette.borderSubtle.color, lineWidth: 1))
    }
}

/// The shared sunken search/filter field with a magnifier, replacing the stock
/// rounded-border text field everywhere chrome should look custom.
struct FilterField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(Palette.textTertiary.color)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textPrimary.color)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: TypeScale.label))
                        .foregroundStyle(Palette.textTertiary.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.md)
            .fill(Palette.surfaceSunken.color))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
    }
}

/// A titled panel section rendered as a card: uppercase caption with an accent
/// tick, content on the elevated surface. The inspector's grouping unit.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.accent.color)
                    .frame(width: 3, height: 10)
                Text(title.uppercased())
                    .font(.system(size: TypeScale.label, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary.color)
                    .tracking(0.8)
            }
            Card { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label/value row used throughout the inspector. The value is monospaced so
/// numbers line up column-wise.
struct FieldRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 96, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                .foregroundStyle(Palette.textPrimary.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A keyboard-key chip ("⇥", "F", "⇧drag") in the enterprise-CAD status-hint
/// idiom: sunken, monospaced, quiet. Used only inside `HintBar`.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.textSecondary.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Palette.surfaceSunken.color))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Palette.borderSubtle.color, lineWidth: 1))
    }
}

/// One entry in a `HintBar`: a key (or gesture) plus what it does.
struct Hint: Identifiable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// The Blender/Fusion-style status hint line: a single quiet row of
/// key → action pairs pinned to an edge of the viewport. Deliberately inert —
/// no animation, no chrome beyond the shared HUD surface — with a close
/// button so it can be dismissed for good (persisted by the caller).
struct HintBar: View {
    let hints: [Hint]
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(hints) { hint in
                HStack(spacing: Spacing.xxs) {
                    KeyCap(text: hint.key)
                    Text(hint.label)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textTertiary.color)
                }
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textTertiary.color)
            }
            .buttonStyle(.plain)
            .help("Hide shortcut hints")
            .accessibilityIdentifier("hintBar.dismiss")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Capsule().fill(Palette.surfaceElevated.color.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Palette.borderSubtle.color, lineWidth: 1))
        .accessibilityIdentifier("hintBar")
    }
}

/// Human-readable rendering of a typed USD attribute value for the inspector.
enum ValueFormatter {
    static func string(_ value: AttributeValue) -> String {
        switch value {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return trimmed(d)
        case .string(let s): return "\"\(s)\""
        case .token(let t): return t
        case .asset(let a): return "@\(a)@"
        case .vector(let v): return "(" + v.map(trimmed).joined(separator: ", ") + ")"
        case .matrix4: return "matrix4d(…)"
        case .intArray(let a): return array(a.map(String.init))
        case .doubleArray(let a): return array(a.map(trimmed))
        case .stringArray(let a): return array(a)
        case .tokenArray(let a): return array(a)
        case .float3Array(let a): return "float3[\(a.count / 3)]"
        case .quatfArray(let a): return "quatf[\(a.count / 4)]"
        case .matrix4dArray(let a): return "matrix4d[\(a.count / 16)]"
        case .unsupported(let name): return "‹\(name)›"
        }
    }

    private static func trimmed(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(format: "%.4g", d)
    }

    private static func array(_ items: [String]) -> String {
        let shown = items.prefix(6).joined(separator: ", ")
        return items.count > 6 ? "[\(shown), … +\(items.count - 6)]" : "[\(shown)]"
    }
}
