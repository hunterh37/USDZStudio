import SwiftUI
import DicyaninDesignSystem

/// Modal-feeling progress veil shown over the viewport while a dropped (or
/// opened) file is being imported through the USD bridge. The bridge snapshot
/// is a single async round-trip with no fractional progress to report, so this
/// is deliberately an indeterminate *circular* spinner (specs/viewport.md: keep
/// long operations legible — never a frozen, empty viewport).
///
/// It fills its container and swallows hit-testing so the half-loaded stage
/// underneath can't be clicked mid-import.
public struct ImportProgressOverlay: View {

    /// The file being imported, surfaced under the spinner so the user knows
    /// which drop is in flight.
    let fileName: String?

    public init(fileName: String? = nil) {
        self.fileName = fileName
    }

    public var body: some View {
        ZStack {
            // Dim scrim over the viewport.
            Palette.viewportBackground.color.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: Spacing.md) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Palette.accent.color)

                VStack(spacing: Spacing.xxs) {
                    Text("Importing…")
                        .font(.system(size: TypeScale.body, weight: .medium))
                        .foregroundStyle(Palette.textPrimary.color)
                    if let fileName, !fileName.isEmpty {
                        Text(fileName)
                            .font(.system(size: TypeScale.caption))
                            .foregroundStyle(Palette.textSecondary.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
        }
        // Block interaction with the stage underneath while importing.
        .contentShape(Rectangle())
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fileName.map { "Importing \($0)" } ?? "Importing")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("viewport.importProgress")
    }
}
