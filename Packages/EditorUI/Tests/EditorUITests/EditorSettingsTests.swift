import Testing
import Foundation
@testable import EditorUI
import ViewportKit
import ValidationKit

/// Unit tests for the persisted settings model. Each test uses an ephemeral
/// `UserDefaults` suite so nothing touches the real app domain and runs are
/// order-independent.
@MainActor
struct EditorSettingsTests {

    /// A fresh, isolated defaults suite per test.
    private func makeDefaults() -> UserDefaults {
        let suite = "editor.settings.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsWhenStoreEmpty() {
        let settings = EditorSettings(defaults: makeDefaults())
        #expect(settings.exportFormat == .usdz)
        #expect(settings.exportProfileID == ValidationProfile.arkit.id)
        #expect(settings.exportProfile.id == ValidationProfile.arkit.id)
        #expect(settings.showHotkeyHints == true)
        #expect(settings.restoreEnvironmentOnLaunch == true)
        #expect(settings.hasSeenTutorial == false)
    }

    @Test func exportFormatPersistsAndReloads() {
        let defaults = makeDefaults()
        do {
            let settings = EditorSettings(defaults: defaults)
            settings.exportFormat = .usda
            #expect(settings.exportFormat == .usda)
        }
        // A second instance over the same store sees the persisted value.
        #expect(EditorSettings(defaults: defaults).exportFormat == .usda)
        #expect(defaults.string(forKey: EditorSettings.Key.exportFormat) == "usda")
    }

    @Test func exportProfilePersistsAndResolves() {
        let defaults = makeDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.exportProfileID = ValidationProfile.arkitStrict.id
        #expect(settings.exportProfile.id == ValidationProfile.arkitStrict.id)
        #expect(EditorSettings(defaults: defaults).exportProfileID == ValidationProfile.arkitStrict.id)
    }

    @Test func unknownProfileDegradesToArkit() {
        let defaults = makeDefaults()
        defaults.set("no-such-profile", forKey: EditorSettings.Key.exportProfile)
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.exportProfileID == "no-such-profile")
        #expect(settings.exportProfile.id == ValidationProfile.arkit.id)
    }

    @Test func invalidExportFormatDegradesToUsdz() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: EditorSettings.Key.exportFormat)
        #expect(EditorSettings(defaults: defaults).exportFormat == .usdz)
    }

    @Test func showHotkeyHintsPersists() {
        let defaults = makeDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.showHotkeyHints = false
        #expect(settings.showHotkeyHints == false)
        #expect(EditorSettings(defaults: defaults).showHotkeyHints == false)
    }

    @Test func environmentRoundTrips() {
        let defaults = makeDefaults()
        let settings = EditorSettings(defaults: defaults)
        var env = EnvironmentSettings()
        env.selectPreset(.outdoor)
        env.setExposure(ev: 2.5)
        settings.saveEnvironment(env)

        let loaded = settings.loadEnvironment()
        #expect(loaded.preset == .outdoor)
        #expect(loaded.exposureEV == 2.5)
    }

    @Test func environmentNotRestoredWhenDisabled() {
        let defaults = makeDefaults()
        let settings = EditorSettings(defaults: defaults)
        var env = EnvironmentSettings()
        env.selectPreset(.outdoor)
        settings.saveEnvironment(env)

        settings.restoreEnvironmentOnLaunch = false
        // Disabled → returns defaults, not the saved sunset preset.
        #expect(settings.loadEnvironment().preset == EnvironmentSettings().preset)
    }

    @Test func loadEnvironmentDefaultsWhenNothingSaved() {
        let settings = EditorSettings(defaults: makeDefaults())
        #expect(settings.loadEnvironment() == EnvironmentSettings())
    }

    @Test func loadEnvironmentDefaultsOnCorruptData() {
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: EditorSettings.Key.environment)
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.loadEnvironment() == EnvironmentSettings())
    }

    @Test func resetWelcomeTourClearsFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: EditorSettings.Key.hasSeenTutorial)
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.hasSeenTutorial == true)
        settings.resetWelcomeTour()
        #expect(settings.hasSeenTutorial == false)
        #expect(defaults.bool(forKey: EditorSettings.Key.hasSeenTutorial) == false)
    }

    @Test func restoreTogglePersists() {
        let defaults = makeDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.restoreEnvironmentOnLaunch = false
        #expect(EditorSettings(defaults: defaults).restoreEnvironmentOnLaunch == false)
    }
}
