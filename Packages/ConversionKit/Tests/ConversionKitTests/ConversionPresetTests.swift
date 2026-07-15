import Testing
@testable import ConversionKit

@Suite("ConversionPreset")
struct ConversionPresetTests {

    @Test func builtinsExposeStableIdentifiers() {
        #expect(ConversionPreset.builtins.map(\.id) == ["quicklook-strict", "ecommerce", "lossless"])
        #expect(ConversionPreset.identifiers == "quicklook-strict, ecommerce, lossless")
    }

    @Test func lookupIsCaseInsensitiveAndReturnsNilForUnknown() {
        #expect(ConversionPreset.named("ECOMMERCE") == .ecommerce)
        #expect(ConversionPreset.named("quicklook-strict") == .quickLookStrict)
        #expect(ConversionPreset.named("nope") == nil)
    }

    @Test func ecommercePrioritizesSmallLossyOutput() {
        let policy = ConversionPreset.ecommerce.texturePolicy
        #expect(policy.maxSize == 1024)
        #expect(policy.encodeBaseColorAsJPEG)
    }

    @Test func quickLookStrictMatchesDefaultTexturePolicy() {
        // The default preset must not diverge from an unconfigured pipeline.
        #expect(ConversionPreset.quickLookStrict.texturePolicy == TexturePolicy())
    }

    @Test func losslessNeverDownscalesOrReencodes() {
        let policy = ConversionPreset.lossless.texturePolicy
        #expect(policy.maxSize == .max)
        #expect(!policy.encodeBaseColorAsJPEG)
    }
}
