import Testing
import Foundation
import simd
@testable import ViewportKit

@Suite("EnvironmentSettings #126 integration + Codable")
struct EnvironmentSettingsCodableTests {

    @Test func defaultsMatchQuickLookParityIntent() {
        let s = EnvironmentSettings()
        #expect(s.grounding == GroundingSettings())
        #expect(s.lighting == .quickLook)
        #expect(s.toneMapping == .aces)
    }

    @Test func fullRoundTripPreservesAllFields() throws {
        var s = EnvironmentSettings(background: .arPreview,
                                    grounding: GroundingSettings(isEnabled: true, softness: 0.3),
                                    lighting: .quickLook,
                                    toneMapping: .reinhard)
        s.grounding.setSoftness(0.42)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(EnvironmentSettings.self, from: data)
        #expect(back == s)
        #expect(back.background == .arPreview)
        #expect(back.toneMapping == .reinhard)
        #expect(abs(back.grounding.softness - 0.42) < 1e-6)
    }

    @Test func legacyJSONWithoutNewFieldsDecodesOntoDefaults() throws {
        // Simulates settings persisted before #126 landed: no grounding /
        // lighting / toneMapping keys. Must decode onto the parity defaults
        // rather than throwing (EditorSettings relies on this).
        let legacy = """
        {"preset":"outdoor","exposureEV":1.5,"intensity":0.5,"background":{"environment":{}}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(EnvironmentSettings.self, from: legacy)
        #expect(s.preset == .outdoor)
        #expect(s.exposureEV == 1.5)
        #expect(s.grounding == GroundingSettings())
        #expect(s.lighting == .quickLook)
        #expect(s.toneMapping == .aces)
        #expect(s.background == .environment)
    }

    @Test func emptyJSONDecodesToFullDefaults() throws {
        let s = try JSONDecoder().decode(EnvironmentSettings.self, from: "{}".data(using: .utf8)!)
        #expect(s == EnvironmentSettings())
    }

    @Test func arPreviewBackgroundRoundTrips() throws {
        let s = EnvironmentSettings(background: .arPreview)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(EnvironmentSettings.self, from: data)
        #expect(back.background == .arPreview)
    }
}
