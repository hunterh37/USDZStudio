import SwiftUI
import DicyaninDesignSystem

/// The transient shortcut hint that fades in when a scene first appears, holds,
/// then auto-fades. All show/hold/fade/gate decisions live in the injected
/// `ShortcutHintController`; this view only maps the controller's `opacity` to
/// the rendered surface and drives the animation clock with a `TimelineView`.
struct ShortcutHintToast: View {
    @Bindable var controller: ShortcutHintController

    var body: some View {
        // A short display-link clock advances the controller while it is
        // visible; the controller decides opacity/phase — the view never times.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !controller.isVisible)) { context in
            content
                .onChange(of: context.date) { _, date in
                    controller.tick(now: date.timeIntervalSinceReferenceDate)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.isVisible {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "keyboard")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.accent.color)
                Text(controller.text)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Capsule().fill(Palette.surfaceElevated.color.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Palette.borderSubtle.color, lineWidth: 1))
            .opacity(controller.opacity)
            .accessibilityIdentifier("shortcutHintToast")
            .allowsHitTesting(false)   // never intercepts a viewport gesture
        }
    }
}
