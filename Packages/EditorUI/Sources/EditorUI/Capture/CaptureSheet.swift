import SwiftUI
import UniformTypeIdentifiers
import CaptureKit
import DicyaninDesignSystem

/// Capture-import sheet (Phase 2.5): drop or choose a folder of photographs →
/// pick a detail tier → read the pre-flight verdict → reconstruct into an
/// editable USDZ via Apple's Object Capture, then open the result in the editor.
///
/// A thin, declarative view over `CaptureImportModel`: all logic and side
/// effects live in the model + injected service (CLAUDE.md — Views stay
/// declarative and thin). Mirrors `ConversionSheet`'s layout and design tokens.
struct CaptureSheet: View {
    /// The view model, created by the shell with a real service injected.
    @State var model: CaptureImportModel
    /// Opens the produced USDZ as an editable document (wired to the shell's
    /// re-import path).
    let onOpen: (URL) async -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Capture from Photos")
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            Text("Reconstruct a real object into an editable USDZ from a folder of photographs.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textSecondary.color)

            folderPicker
            options
            Divider().overlay(Palette.panelBorder.color)
            statusArea

            HStack {
                statusLabel
                Spacer()
                if model.isRunning {
                    Button("Cancel", action: model.cancel)
                }
                Button("Close", action: onClose)
                Button(action: start) {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    else { Text("Start Capture") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 580, height: 600)
        .background(Palette.windowBackground.color)
        // Accept a dropped folder as well as the Choose button.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.selectFolder(folderURL(url)) } }
            }
            return true
        }
    }

    // MARK: Sections

    private var folderPicker: some View {
        HStack(spacing: Spacing.sm) {
            Button("Choose Folder…", action: pickFolder)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.folder?.lastPathComponent ?? "No folder selected — drop a folder of photos here")
                    .font(.system(size: TypeScale.body, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary.color)
                    .lineLimit(1)
                if model.folder != nil {
                    Text("\(model.images.count) photo\(model.images.count == 1 ? "" : "s") found")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
            Spacer()
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Detail")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
                Picker("", selection: $model.detail) {
                    ForEach(CaptureDetail.allCases, id: \.self) { d in
                        Text(d.rawValue.capitalized).tag(d)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("", selection: $model.profile) {
                    Text("ARKit").tag(CaptureProfile.arkit)
                    Text("ARKit (strict)").tag(CaptureProfile.arkitStrict)
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }
            Text(model.materialCaveat)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textSecondary.color)

            HStack(spacing: Spacing.sm) {
                Toggle("Normalize scale to", isOn: $model.normalizeScale)
                    .font(.system(size: TypeScale.body))
                Picker("", selection: $model.metersPerUnit) {
                    ForEach([0.01, 0.1, 1.0], id: \.self) { Text("\($0) m/unit").tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!model.normalizeScale)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                preflightList
                if model.showsGuidance { guidanceChecklist }
                progressOrCompletion
            }
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.viewportBackground.color))
    }

    @ViewBuilder
    private var preflightList: some View {
        if model.folder == nil {
            Text("Pre-flight results will appear here once you choose a folder.")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
        } else {
            ForEach(Array(model.blockingIssues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "xmark.octagon.fill")
                    .font(.system(size: TypeScale.inspectorField))
                    .foregroundStyle(Palette.error.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.advisories.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: TypeScale.inspectorField))
                    .foregroundStyle(Palette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.blockingIssues.isEmpty && model.advisories.isEmpty {
                Label("Pre-flight passed — ready to reconstruct.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: TypeScale.inspectorField))
                    .foregroundStyle(Palette.accent.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var guidanceChecklist: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Capture tips for a cleaner mesh")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            ForEach(Self.guidanceTips, id: \.self) { tip in
                Text("•  \(tip)")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.panelBorder.color.opacity(0.15)))
    }

    @ViewBuilder
    private var progressOrCompletion: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case let .reconstructing(fraction):
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconstructing… \(Int(fraction * 100))%")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                ProgressView(value: fraction)
                    .tint(Palette.accent.color)
            }
        case let .completed(url):
            Label("Reconstructed \(url.lastPathComponent) and opened it in the editor.",
                  systemImage: "checkmark.seal.fill")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.accent.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.error.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let failure = model.failureMessage {
            Label(failure, systemImage: "exclamationmark.circle")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.error.color)
                .lineLimit(2)
        }
    }

    // MARK: Actions

    private func start() {
        model.start(onComplete: onOpen)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.selectFolder(url)
        }
    }

    /// Resolve a dropped item to a folder: if a file was dropped, use its parent
    /// so a user can drag any photo from the set.
    private func folderURL(_ dropped: URL) -> URL {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dropped.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? dropped : dropped.deletingLastPathComponent()
    }

    /// In-sheet capture guidance shown when overlap/near-minimum advisories fire.
    static let guidanceTips = [
        "Shoot from equidistant angles all the way around the object.",
        "Use soft, diffuse lighting — avoid hard shadows and glare.",
        "Keep high overlap between consecutive photos (~70%).",
        "Capture multiple heights: low, eye-level, and high.",
    ]
}
