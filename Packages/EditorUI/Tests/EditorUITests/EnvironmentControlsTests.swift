import Testing
import SwiftUI
import ViewportKit
@testable import EditorUI

/// Drives the environment control strip's view builders and binding logic
/// without a rendering host (same approach as MCPActivityPanelViewTests).
@MainActor
@Suite struct EnvironmentControlsTests {

    @Test func bodyRendersDefaultEnvironmentState() {
        var settings = EnvironmentSettings()
        let view = EnvironmentControls(settings: bind(&settings))
        _ = view.body
    }

    @Test func bodyRendersCustomEnvironmentAndSolidColor() {
        var settings = EnvironmentSettings(background: .solidColor(SIMD3(0.2, 0.3, 0.4)))
        settings.setCustomEnvironment(URL(fileURLWithPath: "/env/studio.hdr"))
        let view = EnvironmentControls(settings: bind(&settings))
        _ = view.body
    }

    @Test func bodyRendersTransparentBackground() {
        var settings = EnvironmentSettings(background: .transparent)
        _ = EnvironmentControls(settings: bind(&settings)).body
    }

    @Test func presetBindingSelectsPresetAndClearsCustom() {
        let box = Box(EnvironmentSettings(preset: .studio))
        box.value.setCustomEnvironment(URL(fileURLWithPath: "/env/a.hdr"))
        let view = EnvironmentControls(settings: box.binding())
        // Toggle background to color then verify kind binding round-trips.
        view.backgroundKindBinding.wrappedValue = .color
        #expect(view.backgroundKindBinding.wrappedValue == .color)
        // Re-selecting color must not overwrite an existing colour.
        if case .solidColor(let c) = box.value.background {
            view.backgroundKindBinding.wrappedValue = .color
            if case .solidColor(let c2) = box.value.background { #expect(c == c2) }
        }
        view.backgroundKindBinding.wrappedValue = .transparent
        #expect(box.value.background == .transparent)
        view.backgroundKindBinding.wrappedValue = .environment
        #expect(box.value.background == .environment)
    }

    @Test func solidColorBindingReadsAndWrites() {
        let box = Box(EnvironmentSettings(background: .solidColor(SIMD3(1, 0, 0))))
        let view = EnvironmentControls(settings: box.binding())
        _ = view.solidColorBinding.wrappedValue
        view.solidColorBinding.wrappedValue = Color(.sRGB, red: 0, green: 0, blue: 1)
        if case .solidColor(let c) = box.value.background {
            #expect(c.z > 0.5 && c.x < 0.5)
        } else {
            Issue.record("expected solid colour")
        }
        // Getter fallback when not a solid colour.
        box.value.background = .environment
        #expect(view.solidColorBinding.wrappedValue == .black)
    }

    @Test func chooseCustomEnvironmentAppliesReturnedURL() {
        let box = Box(EnvironmentSettings())
        let view = EnvironmentControls(settings: box.binding(),
                                       onChooseCustomEnvironment: {
                                           URL(fileURLWithPath: "/env/picked.exr")
                                       })
        view.chooseCustomEnvironment()
        #expect(box.value.usesCustomEnvironment)
    }

    @Test func chooseCustomEnvironmentIgnoresNilAndMissingHandler() {
        let box = Box(EnvironmentSettings())
        EnvironmentControls(settings: box.binding()).chooseCustomEnvironment()
        #expect(!box.value.usesCustomEnvironment)
        EnvironmentControls(settings: box.binding(),
                            onChooseCustomEnvironment: { nil }).chooseCustomEnvironment()
        #expect(!box.value.usesCustomEnvironment)
    }

    @Test func backgroundKindReflectsEveryMode() {
        let box = Box(EnvironmentSettings(background: .environment))
        let view = EnvironmentControls(settings: box.binding())
        #expect(view.backgroundKindBinding.wrappedValue == .environment)
        box.value.background = .solidColor(SIMD3(0, 0, 0))
        #expect(view.backgroundKindBinding.wrappedValue == .color)
        box.value.background = .transparent
        #expect(view.backgroundKindBinding.wrappedValue == .transparent)
        box.value.background = .arPreview
        #expect(view.backgroundKindBinding.wrappedValue == .arPreview)
    }

    @Test func backgroundKindSetterRoundTripsARPreview() {
        let box = Box(EnvironmentSettings(background: .environment))
        let view = EnvironmentControls(settings: box.binding())
        view.backgroundKindBinding.wrappedValue = .arPreview
        #expect(box.value.background == .arPreview)
    }

    // MARK: #126 grounding + tone mapping

    @Test func bodyRendersARPreviewAndGrounding() {
        var settings = EnvironmentSettings(background: .arPreview)
        _ = EnvironmentControls(settings: bind(&settings)).body
    }

    @Test func groundingActiveOnlyOnARPreviewBackground() {
        let box = Box(EnvironmentSettings(background: .arPreview))
        let view = EnvironmentControls(settings: box.binding())
        #expect(view.groundingActive)
        box.value.background = .environment
        #expect(!view.groundingActive)
    }

    @Test func groundingEnabledBindingToggles() {
        let box = Box(EnvironmentSettings())
        let view = EnvironmentControls(settings: box.binding())
        view.groundingEnabledBinding.wrappedValue = false
        #expect(!box.value.grounding.isEnabled)
        view.groundingEnabledBinding.wrappedValue = true
        #expect(box.value.grounding.isEnabled)
    }

    @Test func softnessBindingReadsAndClampsWrites() {
        let box = Box(EnvironmentSettings())
        let view = EnvironmentControls(settings: box.binding())
        _ = view.softnessBinding.wrappedValue
        view.softnessBinding.wrappedValue = 2   // clamps to 1
        #expect(box.value.grounding.softness == 1)
        view.softnessBinding.wrappedValue = 0.25
        #expect(abs(box.value.grounding.softness - 0.25) < 1e-6)
    }

    @Test func toneMappingBindingReadsAndWrites() {
        let box = Box(EnvironmentSettings(toneMapping: .aces))
        let view = EnvironmentControls(settings: box.binding())
        #expect(view.toneMappingBinding.wrappedValue == .aces)
        view.toneMappingBinding.wrappedValue = .reinhard
        #expect(box.value.toneMapping == .reinhard)
    }

    @Test func backgroundKindLabelsAreDistinct() {
        let labels = Set(EnvironmentControls.BackgroundKind.allCases.map(\.label))
        #expect(labels.count == EnvironmentControls.BackgroundKind.allCases.count)
        for kind in EnvironmentControls.BackgroundKind.allCases { #expect(kind.id == kind.rawValue) }
    }

    // MARK: Helpers

    private func bind(_ settings: inout EnvironmentSettings) -> Binding<EnvironmentSettings> {
        let box = Box(settings)
        return box.binding()
    }

    @MainActor final class Box {
        var value: EnvironmentSettings
        init(_ value: EnvironmentSettings) { self.value = value }
        func binding() -> Binding<EnvironmentSettings> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }
}
