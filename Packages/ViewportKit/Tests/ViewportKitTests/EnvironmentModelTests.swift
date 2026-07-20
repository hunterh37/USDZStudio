import Testing
import Foundation
import simd
@testable import ViewportKit

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("EnvironmentModel")
struct EnvironmentModelTests {

    // MARK: Presets

    @Test func everyPresetHasDistinctResourceAndLabel() {
        let presets = EnvironmentModel.IBLPreset.allCases
        #expect(presets.count == 4)
        let names = Set(presets.map(\.resourceName))
        let labels = Set(presets.map(\.displayName))
        #expect(names.count == presets.count)
        #expect(labels.count == presets.count)
        for preset in presets {
            #expect(preset.id == preset.rawValue)
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.resourceName.isEmpty)
        }
    }

    @Test func flatPresetsExposeConstantColorImageOnesDoNot() {
        #expect(EnvironmentModel.IBLPreset.neutralGray.constantColor == SIMD3<Float>(repeating: 0.5))
        #expect(EnvironmentModel.IBLPreset.pureWhite.constantColor == SIMD3<Float>(repeating: 1))
        #expect(EnvironmentModel.IBLPreset.studio.constantColor == nil)
        #expect(EnvironmentModel.IBLPreset.outdoor.constantColor == nil)
    }

    // MARK: File support

    @Test func supportedExtensionsAreCaseInsensitive() {
        #expect(EnvironmentModel.isSupportedEnvironmentFile(URL(fileURLWithPath: "/x/a.hdr")))
        #expect(EnvironmentModel.isSupportedEnvironmentFile(URL(fileURLWithPath: "/x/a.EXR")))
        #expect(EnvironmentModel.isSupportedEnvironmentFile(URL(fileURLWithPath: "/x/a.Hdr")))
        #expect(!EnvironmentModel.isSupportedEnvironmentFile(URL(fileURLWithPath: "/x/a.png")))
        #expect(!EnvironmentModel.isSupportedEnvironmentFile(URL(fileURLWithPath: "/x/a")))
    }

    // MARK: Exposure

    @Test func exposureMultiplierIsTwoToTheEV() {
        #expect(approx(EnvironmentModel.exposureMultiplier(ev: 0), 1))
        #expect(approx(EnvironmentModel.exposureMultiplier(ev: 1), 2))
        #expect(approx(EnvironmentModel.exposureMultiplier(ev: -1), 0.5))
    }

    @Test func exposureMultiplierClampsOutOfRange() {
        #expect(approx(EnvironmentModel.exposureMultiplier(ev: 100),
                       pow(2, EnvironmentModel.exposureRange.upperBound)))
        #expect(approx(EnvironmentModel.exposureMultiplier(ev: -100),
                       pow(2, EnvironmentModel.exposureRange.lowerBound)))
    }
}

@Suite("EnvironmentSettings")
struct EnvironmentSettingsTests {

    @Test func defaultsAreStudioEnvironment() {
        let s = EnvironmentSettings()
        #expect(s.preset == .studio)
        #expect(s.customEnvironmentURL == nil)
        #expect(approx(s.exposureEV, 0))
        #expect(s.intensity == 1)
        #expect(s.background == .environment)
        #expect(!s.usesCustomEnvironment)
    }

    @Test func initClampsExposureAndIntensity() {
        let hi = EnvironmentSettings(exposureEV: 999, intensity: 999)
        #expect(hi.exposureEV == EnvironmentModel.exposureRange.upperBound)
        #expect(hi.intensity == EnvironmentModel.intensityRange.upperBound)
        let lo = EnvironmentSettings(exposureEV: -999, intensity: -5)
        #expect(lo.exposureEV == EnvironmentModel.exposureRange.lowerBound)
        #expect(lo.intensity == EnvironmentModel.intensityRange.lowerBound)
    }

    @Test func exposureMultiplierReflectsEV() {
        var s = EnvironmentSettings()
        s.setExposure(ev: 2)
        #expect(approx(s.exposureMultiplier, 4))
    }

    @Test func resolvedSourceForImagePreset() {
        let s = EnvironmentSettings(preset: .studio)
        #expect(s.resolvedSource == .presetImage("ibl_studio"))
    }

    @Test func resolvedSourceForConstantColorPreset() {
        let s = EnvironmentSettings(preset: .pureWhite)
        #expect(s.resolvedSource == .constantColor(SIMD3<Float>(repeating: 1)))
    }

    @Test func customFileOverridesPreset() {
        var s = EnvironmentSettings(preset: .studio)
        let url = URL(fileURLWithPath: "/env/custom.exr")
        let accepted = s.setCustomEnvironment(url)
        #expect(accepted)
        #expect(s.usesCustomEnvironment)
        #expect(s.resolvedSource == .customFile(url))
    }

    @Test func unsupportedCustomFileRejectedAndStateUntouched() {
        var s = EnvironmentSettings(preset: .outdoor)
        let accepted = s.setCustomEnvironment(URL(fileURLWithPath: "/env/bad.png"))
        #expect(!accepted)
        #expect(s.customEnvironmentURL == nil)
        #expect(!s.usesCustomEnvironment)
        #expect(s.resolvedSource == .presetImage("ibl_outdoor"))
    }

    @Test func clearCustomFallsBackToPreset() {
        var s = EnvironmentSettings(preset: .outdoor)
        s.setCustomEnvironment(URL(fileURLWithPath: "/env/custom.hdr"))
        s.clearCustomEnvironment()
        #expect(s.customEnvironmentURL == nil)
        #expect(s.resolvedSource == .presetImage("ibl_outdoor"))
    }

    @Test func selectPresetDropsCustomEnvironment() {
        var s = EnvironmentSettings(preset: .studio)
        s.setCustomEnvironment(URL(fileURLWithPath: "/env/custom.hdr"))
        s.selectPreset(.neutralGray)
        #expect(s.preset == .neutralGray)
        #expect(s.customEnvironmentURL == nil)
        #expect(s.resolvedSource == .constantColor(SIMD3<Float>(repeating: 0.5)))
    }

    @Test func usesCustomEnvironmentFalseForUnsupportedURL() {
        // Bypass the guarded setter to prove the getter validates too.
        var s = EnvironmentSettings()
        s.customEnvironmentURL = URL(fileURLWithPath: "/env/nope.png")
        #expect(!s.usesCustomEnvironment)
        #expect(s.resolvedSource == .presetImage("ibl_studio"))
    }

    @Test func settersClampToRanges() {
        var s = EnvironmentSettings()
        s.setExposure(ev: 50)
        #expect(s.exposureEV == EnvironmentModel.exposureRange.upperBound)
        s.setExposure(ev: -50)
        #expect(s.exposureEV == EnvironmentModel.exposureRange.lowerBound)
        s.setIntensity(50)
        #expect(s.intensity == EnvironmentModel.intensityRange.upperBound)
        s.setIntensity(-50)
        #expect(s.intensity == EnvironmentModel.intensityRange.lowerBound)
    }

    @Test func backgroundModesAreEquatable() {
        #expect(EnvironmentModel.Background.environment == .environment)
        #expect(EnvironmentModel.Background.transparent == .transparent)
        #expect(EnvironmentModel.Background.solidColor(SIMD3(0.1, 0.2, 0.3))
                == .solidColor(SIMD3(0.1, 0.2, 0.3)))
        #expect(EnvironmentModel.Background.solidColor(SIMD3(0.1, 0.2, 0.3))
                != .solidColor(SIMD3(0.4, 0.5, 0.6)))
    }

    @Test func roundTripsThroughCodable() throws {
        var s = EnvironmentSettings(preset: .outdoor, exposureEV: 1.5,
                                    intensity: 0.8, background: .solidColor(SIMD3(0.2, 0.3, 0.4)))
        s.setCustomEnvironment(URL(fileURLWithPath: "/env/custom.exr"))
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(EnvironmentSettings.self, from: data)
        #expect(decoded == s)
    }

    @Test func codableCoversEveryBackgroundCase() throws {
        for bg: EnvironmentModel.Background in [.environment, .transparent, .solidColor(SIMD3(1, 0, 0))] {
            let s = EnvironmentSettings(background: bg)
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(EnvironmentSettings.self, from: data) == s)
        }
    }
}
