import SwiftUI
import DicyaninDesignSystem

/// Object-mode status hint line (the enterprise-CAD prompt-line pattern:
/// Blender's status bar, Fusion's command hints): one quiet row naming the
/// shortcuts and gestures nothing else in the UI surfaces — Tab, F, ⇧-drag,
/// scroll, ⇧-click.
///
/// Deliberately minimal: hidden in edit mode (`MeshEditOverlay` owns
/// discoverability there), dismissible for good via `@AppStorage`, and
/// replaced by a single quiet keyboard toggle once dismissed.
public struct ViewportHintOverlay: View {
    @Bindable var document: EditorDocument

    /// Off stays off across launches once dismissed.
    @AppStorage("editor.showHotkeyHints") private var showHotkeyHints = true

    public init(document: EditorDocument) { self.document = document }

    public var body: some View {
        if document.meshEdit == nil {
            if let refusal = document.meshEditRefusal {
                // A refused ⇥ must never be a silent no-op: name the reason
                // where the user is already looking.
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(refusal)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textPrimary.color)
                    Button {
                        document.meshEditRefusal = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("meshEdit.refusal.dismiss")
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, Spacing.sm)
                .accessibilityIdentifier("meshEdit.refusal")
            } else if showHotkeyHints {
                HintBar(hints: [
                    Hint(key: "⇥", label: "Edit Mode"),
                    Hint(key: "F", label: "Frame"),
                    Hint(key: "⇧drag", label: "Pan"),
                    Hint(key: "scroll", label: "Dolly"),
                    Hint(key: "⇧click", label: "Multi-select"),
                ]) {
                    showHotkeyHints = false
                }
                .padding(.bottom, Spacing.sm)
            } else {
                Button {
                    showHotkeyHints = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textTertiary.color)
                        .padding(Spacing.xxs)
                }
                .buttonStyle(.plain)
                .help("Show shortcut hints")
                .accessibilityIdentifier("hintBar.show")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
            }
        }
    }
}
