import Testing
import Foundation
@testable import EditorUI

/// Unit tests for the recolor panel's pure colour math.
struct RecolorPanelTests {

    @Test func linearizeEncodeRoundTrips() {
        for c in [0.0, 0.04, 0.18, 0.5, 1.0] {
            let round = RecolorMath.encode(RecolorMath.linearize(c))
            #expect(abs(round - c) < 1e-9)
        }
    }

    @Test func linearizeIsBelowEncodedForMidtones() {
        // sRGB 0.5 linearizes to ~0.214 (the canonical mid-gray value).
        #expect(abs(RecolorMath.linearize(0.5) - 0.2140) < 0.001)
    }

    @Test func vectorHelpersMapComponentwise() {
        let srgb = [0.0, 0.5, 1.0]
        let lin = RecolorMath.linearize(srgb)
        #expect(lin.count == 3)
        #expect(lin[0] == 0.0)
        #expect(abs(RecolorMath.encode(lin)[1] - 0.5) < 1e-9)
    }

    @Test func deltaEIsZeroForIdenticalColors() {
        #expect(RecolorMath.deltaE([0.2, 0.2, 0.2], [0.2, 0.2, 0.2]) == 0)
    }

    @Test func deltaEWhiteToBlackIs100() {
        // CIELab ΔE between white and black is exactly the L* span, 100.
        let dE = RecolorMath.deltaE([1, 1, 1], [0, 0, 0])
        #expect(abs(dE - 100) < 0.001)
    }

    @Test func deltaEGuardsOnMalformedInput() {
        #expect(RecolorMath.deltaE([1, 1], [0, 0, 0]) == 0)
        #expect(RecolorMath.deltaE([1, 1, 1], []) == 0)
    }
}

/// Document-side recolor helpers used by the panel.
@MainActor
struct RecolorDocumentTests {

    @Test func emptyDocumentHasNoMaterials() {
        #expect(EditorDocument().allMaterials.isEmpty)
    }
}
