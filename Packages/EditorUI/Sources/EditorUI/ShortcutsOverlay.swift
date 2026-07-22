import SwiftUI
import DicyaninDesignSystem

/// The full keyboard-shortcut reference card, summoned by `?` (or the corner
/// affordance / Help menu). Translucent, dismissible, zero persistent chrome:
/// it is absent until requested and `Esc`/`?`/click-away closes it. Groups the
/// entire `ShortcutRegistry` by `group` — the "one place that shows all
/// hotkeys". Reads only from the registry, so no key string is hand-written.
struct ShortcutsOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Click-away scrim.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityIdentifier("shortcutsOverlay.scrim")

            card
                .frame(maxWidth: 560)
                .padding(Spacing.lg)
        }
        .accessibilityIdentifier("shortcutsOverlay")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: TypeScale.title, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary.color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shortcutsOverlay.close")
            }

            // Two-column masonry of groups keeps the card compact.
            let columns = [GridItem(.flexible(), alignment: .top),
                           GridItem(.flexible(), alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
                ForEach(ShortcutRegistry.orderedGroups, id: \.group.id) { entry in
                    groupColumn(entry.group, entry.shortcuts)
                }
            }
        }
        .padding(Spacing.lg)
        .background(RoundedRectangle(cornerRadius: Radius.lg)
            .fill(Palette.panelBackground.color.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg)
            .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private func groupColumn(_ group: ShortcutGroup, _ shortcuts: [ViewportShortcut]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(group.title)
                .font(.system(size: TypeScale.label, weight: .semibold))
                .foregroundStyle(Palette.accent.color)
            ForEach(shortcuts) { shortcut in
                HStack(spacing: Spacing.xs) {
                    KeyCap(text: shortcut.keys)
                    Text(shortcut.title)
                        .font(.system(size: TypeScale.body))
                        .foregroundStyle(Palette.textSecondary.color)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityIdentifier("shortcutsOverlay.group.\(group.id)")
    }
}
