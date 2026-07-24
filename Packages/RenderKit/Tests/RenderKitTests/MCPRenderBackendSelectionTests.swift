import Testing
@testable import RenderKit

/// Policy for choosing the `render_views` backend. The hardcoded ON preference
/// unifies app-hosted rendering onto the RealityKit viewport; headless hosts
/// (which can't drive ViewportKit) fall back to the native SceneKit backend.
@Suite("MCPRenderBackendSelection")
struct MCPRenderBackendSelectionTests {

    /// The flag ships ON: this is the "use the same viewport" switch.
    @Test func preferenceIsHardcodedOn() {
        #expect(MCPRenderBackendSelection.preferViewportRenderer == true)
    }

    /// App-hosted (can drive ViewportKit) + preference on → the unified path.
    @Test func appHostedPrefersViewport() {
        #expect(MCPRenderBackendSelection.backend(canUseViewport: true) == .viewport)
    }

    /// A host that can't render through ViewportKit (headless CLI) always falls
    /// back to native, even with the preference on.
    @Test func headlessFallsBackToNative() {
        #expect(MCPRenderBackendSelection.backend(canUseViewport: false) == .native)
    }

    /// Flipping the preference off forces native everywhere.
    @Test func preferenceOffForcesNative() {
        #expect(MCPRenderBackendSelection.backend(canUseViewport: true, preferViewport: false) == .native)
        #expect(MCPRenderBackendSelection.backend(canUseViewport: false, preferViewport: false) == .native)
    }
}
