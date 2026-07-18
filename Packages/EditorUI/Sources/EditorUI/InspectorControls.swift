import SwiftUI
import AppKit
import DicyaninDesignSystem

/// Blender-4.x-idiom inspector building blocks (specs/design-system.md).
///
/// The inspector hard-matches Blender's Properties editor: flat collapsible
/// sections with a chevron header, and "value slider" fields that scrub on
/// horizontal drag (⇧ = coarse ×10, ⌥ = fine ÷10) and switch to text entry on
/// click. Range-bounded fields render a proportional fill bar, Blender's most
/// recognizable control.

// MARK: - Collapsible section

/// A flat, full-width, collapsible section: chevron + title header with a hover
/// wash, content indented beneath, hairline rule after. Replaces the card-based
/// `PanelSection` inside the inspector only — other panels keep their cards.
struct InspectorSection<Content: View>: View {
    let title: String
    /// Quiet monospaced annotation after the title (counts, type names).
    var subtitle: String?
    @ViewBuilder var content: Content

    @State private var expanded = true
    @State private var hovering = false

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Palette.textSecondary.color)
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: TypeScale.body, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: TypeScale.caption, design: .monospaced))
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 6)
                .background(hovering ? Palette.surfaceHover.color : Palette.surfaceElevated.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("inspector.section.\(title)")

            if expanded {
                VStack(alignment: .leading, spacing: Spacing.xs) { content }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.xs)
                    .padding(.bottom, Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Palette.borderSubtle.color).frame(height: 1)
        }
    }
}

// MARK: - Scrub field (Blender "value slider")

/// A numeric field in Blender's value-slider idiom:
/// - **drag horizontally** to scrub (⇧ coarse ×10, ⌥ fine ÷10, via `ScrubMath`),
///   committing once on release so a scrub is a single undo entry;
/// - **click** to type, committing on submit/blur via `NumericFieldParser`;
/// - an optional `range` clamps input and draws the proportional fill bar.
struct ScrubField: View {
    let value: Double
    /// Short leading label rendered inside the field ("X", "Y", "Z").
    var label: String?
    var labelTint: ColorToken?
    var range: ClosedRange<Double>?
    /// Value change per scrub step (4pt of drag).
    var step: Double = 0.01
    /// Display suffix ("°"); `NumericFieldParser.parse` strips it on entry.
    var suffix: String = ""
    let commit: (Double) -> Void

    @State private var editing = false
    @State private var text = ""
    /// Live, uncommitted value while a scrub drag is in flight.
    @State private var live: Double?
    @State private var dragBase: Double?
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var displayed: Double { live ?? value }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Palette.surfaceSunken.color)

            if let range, !editing {
                GeometryReader { geo in
                    let span = range.upperBound - range.lowerBound
                    let frac = span > 0
                        ? min(max((displayed - range.lowerBound) / span, 0), 1) : 0
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(Palette.accent.color.opacity(0.30))
                        .frame(width: max(0, geo.size.width * frac))
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }

            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary.color)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, Spacing.xs)
                    .focused($focused)
                    .onSubmit(endEditing)
                    .onChange(of: focused) { _, isFocused in if !isFocused { endEditing() } }
                    .onAppear {
                        text = NumericFieldParser.format(value)
                        focused = true
                    }
            } else {
                HStack(spacing: Spacing.xxs) {
                    if let label {
                        Text(label)
                            .font(.system(size: TypeScale.caption, weight: .bold))
                            .foregroundStyle((labelTint ?? Palette.textTertiary).color)
                    }
                    Spacer(minLength: 0)
                    Text(NumericFieldParser.format(displayed) + suffix)
                        .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary.color)
                }
                .padding(.horizontal, Spacing.xs)
                .contentShape(Rectangle())
                .gesture(scrubGesture)
                .onTapGesture { editing = true }
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(borderColor, lineWidth: 1))
        .onHover { inside in
            hovering = inside
            if inside && !editing {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to adjust · ⇧ coarse · ⌥ fine · click to type")
    }

    private var borderColor: Color {
        if editing { return Palette.accent.color }
        return hovering ? Palette.panelBorder.color : Palette.borderSubtle.color
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if dragBase == nil { dragBase = value }
                let flags = NSEvent.modifierFlags
                var next = ScrubMath.value(
                    base: dragBase ?? value,
                    dragDelta: drag.translation.width,
                    step: step,
                    fine: flags.contains(.option),
                    coarse: flags.contains(.shift))
                if let range { next = NumericFieldParser.clamp(next, to: range) }
                live = next
            }
            .onEnded { _ in
                if let live, live != value { commit(live) }
                live = nil
                dragBase = nil
            }
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        guard var parsed = NumericFieldParser.parse(text) else { return }
        if let range { parsed = NumericFieldParser.clamp(parsed, to: range) }
        if parsed != value { commit(parsed) }
    }
}

// MARK: - Axis helpers

/// The X/Y/Z axis tint, Blender gizmo idiom.
func axisTint(_ axis: Int) -> ColorToken {
    switch axis {
    case 0: return Palette.axisX
    case 1: return Palette.axisY
    default: return Palette.axisZ
    }
}

let axisLabels = ["X", "Y", "Z"]

// MARK: - Flat text-entry chrome

/// Sunken flat chrome for plain text fields so they match `ScrubField`.
struct SunkenField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.inspectorField, design: .monospaced))
            .foregroundStyle(Palette.textPrimary.color)
            .padding(.horizontal, Spacing.xs)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Radius.md)
                .fill(Palette.surfaceSunken.color))
            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Palette.borderSubtle.color, lineWidth: 1))
    }
}

extension View {
    func sunkenField() -> some View { modifier(SunkenField()) }
}
