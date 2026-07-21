import SwiftUI
import ViewportKit
import ValidationKit
import DicyaninDesignSystem

/// The Settings (⌘,) window — a tabbed preferences surface over ``EditorSettings``.
/// Thin and declarative: every control is a two-way binding onto the model,
/// which owns persistence. Views carry no business logic.
public struct SettingsView: View {

    /// The shared, persisted settings model. `@Bindable` gives the controls
    /// two-way bindings to the `@Observable` properties.
    @Bindable var settings: EditorSettings

    public init(settings: EditorSettings) {
        self.settings = settings
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            exportTab
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            viewportTab
                .tabItem { Label("Viewport", systemImage: "cube") }
        }
        .frame(width: 460, height: 300)
        .accessibilityLabel("Settings")
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Onboarding") {
                LabeledContent("Welcome Tour") {
                    Button("Show Again on Next Launch") { settings.resetWelcomeTour() }
                        .accessibilityHint("Resets the first-run guided tour so it appears again.")
                }
                Text(settings.hasSeenTutorial
                     ? "You've completed the Welcome Tour."
                     : "The Welcome Tour will show on next launch with no document open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Welcome Tour status")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: Export

    private var exportTab: some View {
        Form {
            Section("Defaults") {
                Picker("Format", selection: $settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .accessibilityLabel("Default export format")

                Picker("Validation profile", selection: $settings.exportProfileID) {
                    ForEach(ValidationProfile.all, id: \.id) { profile in
                        Text(profile.id).tag(profile.id)
                    }
                }
                .accessibilityLabel("Export validation profile")
            }
            Section {
                Text("One-click export writes this format, gated by the selected validation profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: Viewport

    private var viewportTab: some View {
        Form {
            Section("Overlays") {
                Toggle("Show hotkey hints", isOn: $settings.showHotkeyHints)
                    .accessibilityHint("Shows the keyboard-shortcut hint strip over the viewport.")
            }
            Section("Environment & Lighting") {
                Toggle("Restore lighting on launch", isOn: $settings.restoreEnvironmentOnLaunch)
                    .accessibilityHint("Reopens windows with the last-used environment instead of the default.")
                Text("When off, each new window starts with the default studio lighting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Spacing.sm)
    }
}
