import SwiftUI
import ScriptingKit
import DicyaninDesignSystem

/// The run surface for a single script: a generated parameter sheet, a Play
/// button, a determinate progress bar fed by `app.progress`, and a live log
/// console. On a successful mutating run the produced file is re-imported into
/// the scene (handled by the controller's `onReimport`).
struct ScriptRunSheet: View {

    @State var controller: ScriptRunController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.panelBorder.color)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(Palette.panelBorder.color)
            footer
        }
        .frame(width: 560, height: 520)
        .background(Palette.windowBackground.color)
        .task { await controller.loadManifest() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(controller.manifest?.name ?? controller.entry.displayName)
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            if let description = controller.manifest?.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .loadingManifest:
            centered { ProgressView("Loading script…") }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    parameters
                    progressSection
                    consoleSection
                }
                .padding(Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private var parameters: some View {
        if let manifest = controller.manifest {
            if manifest.mutates {
                Toggle("Dry run (report changes without writing)", isOn: $controller.dryRun)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                    .disabled(isRunning)
            }
            if !manifest.arguments.isEmpty {
                Text("Parameters")
                    .font(.system(size: TypeScale.body, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary.color)
                ForEach(manifest.arguments, id: \.name) { argument in
                    parameterRow(argument)
                }
            }
            if manifest.mutates && !controller.dryRun && controller.inputURL == nil {
                Label("Open a file to run this script — it edits the stage.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.warning.color)
            }
        }
    }

    @ViewBuilder
    private func parameterRow(_ argument: ScriptArgument) -> some View {
        let binding = Binding(
            get: { controller.argumentValues[argument.name] ?? "" },
            set: { controller.argumentValues[argument.name] = $0 })
        VStack(alignment: .leading, spacing: 2) {
            if argument.kind == .bool {
                Toggle(argument.name, isOn: Binding(
                    get: { ScriptArgument.isTruthy(binding.wrappedValue) },
                    set: { binding.wrappedValue = $0 ? "true" : "false" }))
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
            } else {
                Text(argument.name)
                    .font(.system(size: TypeScale.inspectorField, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                TextField(argument.defaultValue?.displayString ?? "", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: TypeScale.body, design: .monospaced))
            }
            if !argument.help.isEmpty {
                Text(argument.help)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .disabled(isRunning)
    }

    @ViewBuilder
    private var progressSection: some View {
        if isRunning || controller.progressFraction != nil {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let fraction = controller.progressFraction {
                    ProgressView(value: fraction)
                        .tint(Palette.accent.color)
                        .accessibilityIdentifier("scripts.runProgress")
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Palette.accent.color)
                }
                if !controller.progressMessage.isEmpty {
                    Text(controller.progressMessage)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
        }
    }

    @ViewBuilder
    private var consoleSection: some View {
        if !controller.logLines.isEmpty || isTerminal {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Console")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary.color)
                ScrollView {
                    Text(controller.logLines.isEmpty ? "(no output)"
                         : controller.logLines.joined(separator: "\n"))
                        .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.xs)
                }
                .frame(height: 140)
                .background(Palette.viewportBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                statusBanner
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch controller.phase {
        case .succeeded(let reimported):
            Label(reimported ? "Done — result re-imported into the scene."
                             : "Done.",
                  systemImage: "checkmark.circle")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.success.color)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.error.color)
        default:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Close", action: onClose)
            Spacer()
            Button {
                Task { await controller.run() }
            } label: {
                Label(isRunning ? "Running…" : "Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canRun)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("scripts.runButton")
        }
        .padding(Spacing.sm)
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var isRunning: Bool {
        if case .running = controller.phase { return true }
        return false
    }

    private var isTerminal: Bool {
        switch controller.phase {
        case .succeeded, .failed: return true
        default: return false
        }
    }
}
