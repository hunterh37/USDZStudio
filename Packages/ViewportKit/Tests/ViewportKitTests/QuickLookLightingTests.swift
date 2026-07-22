import Testing
import Foundation
import simd
@testable import ViewportKit

@Suite("QuickLook render-parity models (#126)")
struct QuickLookLightingTests {

    // MARK: Background grounding gate

    @Test func onlyARPreviewGroundsTheModel() {
        #expect(EnvironmentModel.Background.arPreview.groundsModel)
        #expect(!EnvironmentModel.Background.environment.groundsModel)
        #expect(!EnvironmentModel.Background.transparent.groundsModel)
        #expect(!EnvironmentModel.Background.solidColor(SIMD3(repeating: 0.5)).groundsModel)
    }

    // MARK: GroundingSettings

    @Test func groundingClampsSoftnessAndExtentOnInit() {
        let low = GroundingSettings(softness: -5, groundExtentScale: -5)
        #expect(low.softness == GroundingSettings.softnessRange.lowerBound)
        #expect(low.groundExtentScale == GroundingSettings.groundExtentRange.lowerBound)

        let high = GroundingSettings(softness: 99, groundExtentScale: 999)
        #expect(high.softness == GroundingSettings.softnessRange.upperBound)
        #expect(high.groundExtentScale == GroundingSettings.groundExtentRange.upperBound)
    }

    @Test func groundingSetSoftnessClamps() {
        var g = GroundingSettings()
        g.setSoftness(2)
        #expect(g.softness == 1)
        g.setSoftness(-1)
        #expect(g.softness == 0)
        g.setSoftness(0.4)
        #expect(g.softness == 0.4)
    }

    @Test func groundingActiveOnlyWhenEnabledAndGrounded() {
        let on = GroundingSettings(isEnabled: true)
        #expect(on.isActive(for: .arPreview))
        #expect(!on.isActive(for: .environment))
        #expect(!on.isActive(for: .transparent))

        let off = GroundingSettings(isEnabled: false)
        #expect(!off.isActive(for: .arPreview))
        #expect(!off.isActive(for: .environment))
    }

    @Test func groundHalfExtentScalesWithRadiusAndFallsBackForDegenerate() {
        let g = GroundingSettings(groundExtentScale: 6)
        #expect(g.groundHalfExtent(modelRadius: 2) == 12)
        // Non-positive radius falls back to a unit floor.
        #expect(g.groundHalfExtent(modelRadius: 0) == 6)
        #expect(g.groundHalfExtent(modelRadius: -3) == 6)
    }

    // MARK: DirectionalLightSpec

    @Test func lightSpecClampsNegativeIntensity() {
        let s = DirectionalLightSpec(direction: SIMD3(0, -1, 0), intensity: -100)
        #expect(s.intensity == 0)
    }

    @Test func lightSpecNormalizesDirection() {
        let s = DirectionalLightSpec(direction: SIMD3(0, -2, 0), intensity: 1)
        let n = s.normalizedDirection
        #expect(abs(simd_length(n) - 1) < 1e-6)
        #expect(n == SIMD3<Float>(0, -1, 0))
    }

    @Test func lightSpecZeroDirectionFallsBackToDown() {
        let s = DirectionalLightSpec(direction: SIMD3(0, 0, 0), intensity: 1)
        #expect(s.normalizedDirection == SIMD3<Float>(0, -1, 0))
    }

    // MARK: LightingRig

    @Test func quickLookRigHasShadowedKeyAndUnshadowedFill() {
        let rig = LightingRig.quickLook
        #expect(rig.isEnabled)
        #expect(rig.keyLight.castsShadow)
        #expect(!rig.fillLight.castsShadow)
        // Key is brighter than fill (a fill is a soft secondary).
        #expect(rig.keyLight.intensity > rig.fillLight.intensity)
    }

    @Test func rigClampsIBLIntensity() {
        let rig = LightingRig(keyLight: LightingRig.quickLook.keyLight,
                              fillLight: LightingRig.quickLook.fillLight,
                              iblIntensity: 99)
        #expect(rig.iblIntensity == LightingRig.iblIntensityRange.upperBound)

        var mutable = LightingRig.quickLook
        mutable.setIBLIntensity(-1)
        #expect(mutable.iblIntensity == 0)
        mutable.setIBLIntensity(2)
        #expect(mutable.iblIntensity == 2)
    }

    // MARK: ToneMapping

    @Test func toneMappingClampsNegativeToZero() {
        for op in ToneMapping.allCases {
            #expect(op.map(-1) == 0)
        }
    }

    @Test func linearClampsAtOne() {
        #expect(ToneMapping.linear.map(0.5) == 0.5)
        #expect(ToneMapping.linear.map(2) == 1)
        #expect(ToneMapping.linear.map(0) == 0)
    }

    @Test func reinhardNeverReachesOneButIsMonotonic() {
        let r = ToneMapping.reinhard
        #expect(r.map(0) == 0)
        #expect(r.map(1) == 0.5)
        #expect(r.map(1000) < 1)
        #expect(r.map(3) > r.map(1))
    }

    @Test func acesRollsOffHighlightsAndIsMonotonic() {
        let a = ToneMapping.aces
        #expect(a.map(0) < 0.01)
        // A big HDR input maps into [0,1].
        let big = a.map(16)
        #expect(big <= 1 && big > 0.7)
        // Monotonic across the mid-range.
        #expect(a.map(0.5) > a.map(0.2))
        #expect(a.map(1) > a.map(0.5))
    }

    @Test func toneMappingRGBMapsChannelwise() {
        let mapped = ToneMapping.linear.map(SIMD3<Float>(0.25, 2, -1))
        #expect(mapped == SIMD3<Float>(0.25, 1, 0))
    }

    @Test func everyToneMappingHasDistinctDisplayName() {
        let names = Set(ToneMapping.allCases.map(\.displayName))
        #expect(names.count == ToneMapping.allCases.count)
        for op in ToneMapping.allCases {
            #expect(op.id == op.rawValue)
            #expect(!op.displayName.isEmpty)
        }
    }
}
