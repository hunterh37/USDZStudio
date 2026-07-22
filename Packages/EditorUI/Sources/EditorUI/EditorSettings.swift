import Foundation
import Observation
import ViewportKit
import ValidationKit

/// App-wide, persisted user preferences — the single model behind the Settings
/// (⌘,) window and the one place the scattered `@AppStorage` keys are given
/// types, defaults, and validation.
///
/// State is stored in an injectable `UserDefaults` (the standard suite in the
/// app, an ephemeral suite in tests) so every accessor is unit-testable without
/// touching global state. The keys are deliberately the *same* strings the
/// views' `@AppStorage` wrappers already use, so a value written here is seen by
/// those wrappers and vice-versa — this model consolidates them rather than
/// forking a second source of truth.
///
/// Only preferences that are actually wired to behaviour live here; a setting
/// with no effect is worse than no setting.
@Observable
@MainActor
public final class EditorSettings: HintPreferenceStore {

    /// Persisted-key namespace. Kept identical to the historical `@AppStorage`
    /// keys so this model and those wrappers share storage.
    public enum Key {
        public static let exportFormat = "editor.export.format"
        public static let exportProfile = "editor.export.profile"
        public static let showHotkeyHints = "editor.showHotkeyHints"
        public static let hasSeenTutorial = "editor.hasSeenTutorial"
        public static let environment = "editor.environment"
        public static let restoreEnvironmentOnLaunch = "editor.environment.restoreOnLaunch"
    }

    /// Backing store. `@ObservationIgnored` because change tracking is driven by
    /// the typed properties below, not the store reference itself.
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Seed observable mirrors from the store once; writes go back through
        // the setters so `@Observable` sees every change and views re-render.
        _exportFormat = Self.readFormat(defaults)
        _exportProfileID = defaults.string(forKey: Key.exportProfile) ?? ValidationProfile.arkit.id
        _showHotkeyHints = defaults.object(forKey: Key.showHotkeyHints) as? Bool ?? true
        _restoreEnvironmentOnLaunch =
            defaults.object(forKey: Key.restoreEnvironmentOnLaunch) as? Bool ?? true
    }

    // MARK: Export defaults

    private var _exportFormat: ExportFormat
    /// Default container for one-click export (mirrors the export panel).
    public var exportFormat: ExportFormat {
        get { _exportFormat }
        set {
            _exportFormat = newValue
            defaults.set(newValue.rawValue, forKey: Key.exportFormat)
        }
    }

    private var _exportProfileID: String
    /// Validation profile the export gate is evaluated against. Persisted as its
    /// stable id; an unknown persisted id degrades to `.arkit` on read.
    public var exportProfileID: String {
        get { _exportProfileID }
        set {
            _exportProfileID = newValue
            defaults.set(newValue, forKey: Key.exportProfile)
        }
    }

    /// The resolved profile, degrading to `.arkit` when the stored id is unknown
    /// (e.g. a profile removed in a later build), so export never wedges.
    public var exportProfile: ValidationProfile {
        ValidationProfile.all.first { $0.id == _exportProfileID } ?? .arkit
    }

    // MARK: Viewport

    private var _showHotkeyHints: Bool
    /// Whether the viewport shows its hotkey-hint overlay.
    public var showHotkeyHints: Bool {
        get { _showHotkeyHints }
        set {
            _showHotkeyHints = newValue
            defaults.set(newValue, forKey: Key.showHotkeyHints)
        }
    }

    private var _restoreEnvironmentOnLaunch: Bool
    /// When true, `loadEnvironment()` returns the last-saved lighting; when
    /// false it returns defaults (a fresh scene each launch).
    public var restoreEnvironmentOnLaunch: Bool {
        get { _restoreEnvironmentOnLaunch }
        set {
            _restoreEnvironmentOnLaunch = newValue
            defaults.set(newValue, forKey: Key.restoreEnvironmentOnLaunch)
        }
    }

    // MARK: Environment persistence

    /// Persists the viewport environment/lighting so it survives relaunch.
    /// Encoded as JSON under a single key (the value is a small `Codable`).
    public func saveEnvironment(_ settings: EnvironmentSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Key.environment)
    }

    /// The environment to open a new window with: the saved one when
    /// `restoreEnvironmentOnLaunch` is on and a valid value is stored, else the
    /// default lighting.
    public func loadEnvironment() -> EnvironmentSettings {
        guard _restoreEnvironmentOnLaunch,
              let data = defaults.data(forKey: Key.environment),
              let decoded = try? JSONDecoder().decode(EnvironmentSettings.self, from: data)
        else { return EnvironmentSettings() }
        return decoded
    }

    // MARK: Onboarding

    /// Clears the "seen the Welcome Tour" flag so the guided tour shows again on
    /// the next launch with no document. Surfaced as a Settings button.
    public func resetWelcomeTour() {
        defaults.set(false, forKey: Key.hasSeenTutorial)
    }

    /// Whether the first-run tour has been seen (read-only mirror for the UI to
    /// label the reset control).
    public var hasSeenTutorial: Bool {
        defaults.object(forKey: Key.hasSeenTutorial) as? Bool ?? false
    }

    // MARK: Helpers

    private static func readFormat(_ defaults: UserDefaults) -> ExportFormat {
        guard let raw = defaults.string(forKey: Key.exportFormat),
              let format = ExportFormat(rawValue: raw) else { return .usdz }
        return format
    }
}
