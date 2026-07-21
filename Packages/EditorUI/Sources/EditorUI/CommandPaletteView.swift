import SwiftUI
import DicyaninDesignSystem

/// The ⌘K command palette: a centered, focused search field over a ranked list
/// of every editor action, with full keyboard control (↑/↓ to move, ↩ to run,
/// ⎋ to dismiss). Thin by design — all ranking/selection lives in
/// `CommandPaletteModel`; this view only renders and forwards key events.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    /// Dismisses the palette. Called on ⎋, on backdrop click, and after a run.
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Palette.panelBorder.color)
            resultsList
        }
        .frame(width: 560)
        .frame(maxHeight: 440)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.panelBackground.color))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Palette.panelBorder.color))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .onAppear { searchFocused = true }
        // Arrow/return handling lives here (not on the TextField) so it works
        // while the field holds focus; the field only consumes text keys.
        .onKeyPress(.downArrow) { model.moveDown(); return .handled }
        .onKeyPress(.upArrow) { model.moveUp(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.return) { runSelected(); return .handled }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary.color)
            TextField("Search commands…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.title, weight: .regular))
                .foregroundStyle(Palette.textPrimary.color)
                .focused($searchFocused)
                .onSubmit(runSelected)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder
    private var resultsList: some View {
        if model.results.isEmpty {
            Text("No matching commands")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            row(item, isSelected: index == model.selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    runSelected()
                                }
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }
                .onChange(of: model.selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func row(_ item: ActionItem, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(item.title)
                .font(.system(size: TypeScale.body, weight: .medium))
                .foregroundStyle(item.isEnabled ? Palette.textPrimary.color : Palette.textTertiary.color)
            Text(item.category)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textTertiary.color)
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm)
            .fill(isSelected ? Palette.accent.color.opacity(0.18) : .clear)
            .padding(.horizontal, Spacing.xxs))
    }

    /// Runs the highlighted action and dismisses only when it actually ran, so
    /// hitting ↩ on a disabled row (or an empty list) keeps the palette open.
    private func runSelected() {
        if model.runSelected() { onClose() }
    }
}

/// Full-window backdrop that dims the editor and centers the palette. Clicking
/// outside the panel dismisses. Presented as an overlay by the shell.
struct CommandPaletteBackdrop: View {
    @Bindable var model: CommandPaletteModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            CommandPaletteView(model: model, onClose: onClose)
                .padding(.top, 80)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .transition(.opacity)
    }
}
