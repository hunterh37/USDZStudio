import SwiftUI
import DicyaninDesignSystem

/// The interactive Python **console** (REPL) sheet — a thin renderer over
/// `ReplController`. It shows the running transcript, a continuation-aware input
/// prompt, and surfaces I/O errors; all orchestration (buffering, running one
/// process per submission, recording one undoable command) lives in the
/// controller, which is unit-tested with no Python.
struct ConsolePanel: View {
    let controller: ReplController
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header
            transcript
            if let ioError = controller.ioError {
                errorBanner(ioError)
            }
            prompt
        }
        .padding(Spacing.lg)
        .frame(width: 620, height: 460)
        .background(Palette.windowBackground.color)
        .onAppear { promptFocused = true }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Python Console")
                    .font(.system(size: TypeScale.title, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Text("`stage`, `selection`, and `app` are bound. Call `stage.Save()` to author an undoable edit.")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer()
            Button("Done", action: onClose).keyboardShortcut(.cancelAction)
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(controller.transcript) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("›› \(line.entry.input)")
                            .foregroundStyle(Palette.accent.color)
                        if !line.entry.output.isEmpty {
                            Text(line.entry.output).foregroundStyle(Palette.textPrimary.color)
                        }
                        if !line.entry.diagnostics.isEmpty {
                            Text(line.entry.diagnostics)
                                .foregroundStyle(line.entry.isError ? Palette.error.color
                                                                     : Palette.textSecondary.color)
                        }
                    }
                    .font(.system(size: TypeScale.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surfaceElevated.color))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(Palette.panelBorder.color, lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Palette.error.color)
    }

    private var prompt: some View {
        HStack(spacing: Spacing.sm) {
            Text(controller.needsContinuation ? "..." : ">>>")
                .font(.system(size: TypeScale.body, design: .monospaced))
                .foregroundStyle(Palette.textSecondary.color)
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body, design: .monospaced))
                .focused($promptFocused)
                .onSubmit(run)
                .accessibilityIdentifier("console.input")
            Button(action: run) {
                Image(systemName: "return")
            }
            .disabled(controller.isRunning)
            .accessibilityIdentifier("console.run")
        }
        .padding(Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surfaceSunken.color))
    }

    private func run() {
        let line = draft
        draft = ""
        Task { await controller.submit(line: line) }
    }
}
