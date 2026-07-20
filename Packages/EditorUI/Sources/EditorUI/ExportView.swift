import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DicyaninDesignSystem
import USDCore
import ValidationKit

/// The prominent top-right export control: a split button whose large primary
/// segment fires a one-click smart export, and whose trailing chevron opens the
/// advanced `ExportPanel`. This is the "big modern button" — accent-filled and
/// visually distinct from the quiet `ToolbarButtonStyle` toolbar actions.
struct ExportButton: View {
    /// Fired by the primary segment: export straight to the smart destination.
    let onQuickExport: () -> Void
    /// Fired by the chevron: open the advanced export panel.
    let onOpenPanel: () -> Void
    /// Disables the whole control (no document/scene to export).
    var isEnabled: Bool = true
    /// Shows a spinner in place of the icon while an export is in flight.
    var isBusy: Bool = false

    @State private var hoveringPrimary = false
    @State private var hoveringChevron = false

    var body: some View {
        HStack(spacing: 0) {
            primarySegment
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(width: 1)
            chevronSegment
        }
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.45)
        .shadow(color: Palette.accent.color.opacity(isEnabled ? 0.35 : 0),
                radius: 8, y: 2)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .contain)
    }

    private var primarySegment: some View {
        Button(action: onQuickExport) {
            HStack(spacing: Spacing.xs) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: TypeScale.heading, weight: .semibold))
                    }
                }
                .frame(width: 16)
                Text("Export")
                    .font(.system(size: TypeScale.heading, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(segmentFill(hovering: hoveringPrimary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringPrimary = $0 }
        .help("Export USDZ to \(smartHint)")
        .accessibilityLabel("Export")
    }

    private var chevronSegment: some View {
        Button(action: onOpenPanel) {
            Image(systemName: "chevron.down")
                .font(.system(size: TypeScale.caption, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xs)
                .frame(minHeight: 24)
                .background(segmentFill(hovering: hoveringChevron))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringChevron = $0 }
        .help("Export options…")
        .accessibilityLabel("Export options")
    }

    private var smartHint: String { "the file's folder" }

    private func segmentFill(hovering: Bool) -> Color {
        hovering
            ? Palette.accent.color.opacity(0.85)
            : Palette.accent.color
    }
}

/// Advanced export panel (sheet). Lets the user pick the output format and a
/// specific destination folder/name, then writes the live scene there. Built
/// from the shared design-system chrome to match the Library/Inspector look.
///
/// The panel is deliberately thin: format selection persists via `@AppStorage`
/// (shared with the one-click button), destination is chosen through an
/// `NSSavePanel`, and the actual write is delegated to the host via `onExport`.
public struct ExportPanel: View {
    /// The currently-open document's URL, used to seed the default file name.
    let sourceURL: URL?
    /// Evaluates the live stage against a named profile. Injected rather than
    /// computed here so the panel stays free of stage access and the gate policy
    /// is tested on its own; `nil` when no document is open.
    let evaluate: ((String) -> ExportGate.Decision)?
    /// Hands a chosen destination back to the host, which performs the write
    /// through the document + bridge executor.
    let onExport: (URL) -> Void
    let onClose: () -> Void

    public init(sourceURL: URL?,
                evaluate: ((String) -> ExportGate.Decision)? = nil,
                onExport: @escaping (URL) -> Void,
                onClose: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.evaluate = evaluate
        self.onExport = onExport
        self.onClose = onClose
    }

    @AppStorage("editor.export.format") private var formatRaw = ExportFormat.usdz.rawValue
    @AppStorage("editor.export.profile") private var profileRaw = ValidationProfile.arkit.id

    /// Set when the user takes the "Export anyway" escape hatch. Deliberately
    /// not persisted: an override is a decision about *this* export, and must be
    /// re-made rather than silently inherited by the next one.
    @State private var overridden = false

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .usdz }

    private var decision: ExportGate.Decision? { evaluate?(profileRaw) }

    /// The primary button is live when there is no gate at all (no document
    /// context) or the gate permits this export.
    private var canExport: Bool {
        guard let decision else { return true }
        return decision.permitsExport(overridden: overridden)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            formatCards
            complianceSection
            destinationHint
            Spacer(minLength: 0)
            footer
        }
        .padding(Spacing.lg)
        .frame(width: 460, height: 560)
        .background(Palette.windowBackground.color)
        // Switching profile re-opens the question, so a prior override must not
        // carry over into a gate the user has not seen yet.
        .onChange(of: profileRaw) { _, _ in overridden = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Export Scene")
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            Text("Write the current scene to a USD file.")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
        }
    }

    private var formatCards: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("FORMAT")
                .font(.system(size: TypeScale.label, weight: .semibold))
                .foregroundStyle(Palette.textTertiary.color)
            ForEach(ExportFormat.allCases) { option in
                formatRow(option)
            }
        }
    }

    private func formatRow(_ option: ExportFormat) -> some View {
        let selected = option == format
        return Button {
            formatRaw = option.rawValue
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: option.systemImage)
                    .font(.system(size: TypeScale.title))
                    .foregroundStyle(selected ? Palette.accent.color : Palette.textSecondary.color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(.system(size: TypeScale.heading, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.color)
                    Text(option.detail)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Palette.accent.color : Palette.borderSubtle.color)
            }
            .padding(Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(selected ? Palette.accent.color.opacity(0.12) : Palette.surfaceElevated.color))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(selected ? Palette.accent.color.opacity(0.5) : Palette.panelBorder.color,
                                  lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var destinationHint: some View {
        Label {
            Text("You'll choose the folder and name next.")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(Palette.textSecondary.color)
        }
    }

    /// The compliance gate: profile picker, verdict, and the offending
    /// diagnostics. Hidden entirely when no document is open, so the panel does
    /// not claim a verdict it has not computed.
    @ViewBuilder
    private var complianceSection: some View {
        if let decision {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("COMPLIANCE")
                        .font(.system(size: TypeScale.label, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary.color)
                    Spacer(minLength: 0)
                    Picker("", selection: $profileRaw) {
                        ForEach(ValidationProfile.all, id: \.id) { profile in
                            Text(profile.id).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                HStack(spacing: Spacing.xs) {
                    Image(systemName: decision.systemImage)
                        .foregroundStyle(verdictTint(decision))
                    Text(decision.headline)
                        .font(.system(size: TypeScale.body))
                        .foregroundStyle(Palette.textPrimary.color)
                }

                if !decision.blockingDiagnostics.isEmpty {
                    diagnosticList(decision.blockingDiagnostics, blocking: true)
                } else if !decision.advisoryDiagnostics.isEmpty {
                    diagnosticList(decision.advisoryDiagnostics, blocking: false)
                }

                if overridden {
                    Text("Exporting anyway — the issues above are unresolved.")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
            .padding(Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Palette.surfaceElevated.color))
        }
    }

    /// The first few diagnostics, most-severe first, with an overflow count so a
    /// long list cannot push the footer off the sheet.
    private func diagnosticList(_ diagnostics: [Diagnostic], blocking: Bool) -> some View {
        let shown = diagnostics.prefix(3)
        let overflow = diagnostics.count - shown.count
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, diagnostic in
                Text("• \(diagnostic.message)")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(blocking ? Palette.textPrimary.color : Palette.textSecondary.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if overflow > 0 {
                Text("+ \(overflow) more — see the Validation drawer")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textTertiary.color)
            }
        }
    }

    private func verdictTint(_ decision: ExportGate.Decision) -> Color {
        switch decision.verdict {
        case .clean: return Palette.success.color
        case .advisory: return Palette.accent.color
        case .blocked: return Palette.error.color
        }
    }

    private var footer: some View {
        HStack {
            // The escape hatch sits apart from the primary action, labelled for
            // exactly what it does, so overriding is a deliberate second choice.
            if let decision, decision.allowsOverride, !overridden {
                Button("Export Anyway") { overridden = true }
                    .help("Export despite \(decision.blockingDiagnostics.count) blocking issue(s).")
            }
            Spacer()
            Button("Cancel", action: onClose)
            Button(action: chooseAndExport) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
    }

    /// Opens a save panel seeded with the smart file name, then hands the chosen
    /// URL to the host and dismisses.
    private func chooseAndExport() {
        // Defence in depth: the button is disabled, but the keyboard shortcut
        // and any future caller route through here too.
        guard canExport else { return }
        let fallback = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let suggested = ExportPlan.smartDestination(
            sourceURL: sourceURL, format: format, fallbackDirectory: fallback)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension)].compactMap { $0 }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        onExport(dest)
        onClose()
    }
}

/// Transient confirmation surface shown after an export: success (with a
/// "Reveal in Finder" action) or failure (with the error, staying until
/// dismissed). Presented as a bottom-anchored overlay by the shell.
struct ExportToast: View {
    let fileName: String
    let errorMessage: String?
    let onReveal: () -> Void
    let onDismiss: () -> Void

    private var isError: Bool { errorMessage != nil }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: TypeScale.title))
                .foregroundStyle(isError ? Palette.error.color : Palette.success.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(isError ? "Export failed" : "Exported \(fileName)")
                    .font(.system(size: TypeScale.body, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(2)
                }
            }
            if !isError {
                Button("Reveal in Finder", action: onReveal)
                    .buttonStyle(.plain)
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(Palette.accent.color)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: TypeScale.caption, weight: .bold))
                    .foregroundStyle(Palette.textSecondary.color)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Palette.surfaceElevated.color)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
        .frame(maxWidth: 460)
    }
}
