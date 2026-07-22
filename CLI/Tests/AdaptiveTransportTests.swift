import Testing
@testable import openusdz

/// The pure per-request routing decision (the stdin/socket loop itself is a
/// coverage-disabled composition root, verified end-to-end by the agent-live
/// recipe).
@Suite struct AdaptiveTransportTests {

    @Test func liveEditorWinsOtherwiseHeadless() {
        // A reachable editor endpoint → relay to the open document.
        #expect(AdaptiveTransport.route(editorLive: true) == .relay)
        // No editor right now → serve the request in-process.
        #expect(AdaptiveTransport.route(editorLive: false) == .inProcess)
    }

    @Test func routeIsRecomputedPerCall() {
        // The decision is a pure function of the *current* liveness, so the same
        // long-lived server flips to relay the instant the editor appears and
        // back to headless if it goes away — this is the whole fix.
        let sequence = [false, false, true, true, false].map(AdaptiveTransport.route(editorLive:))
        #expect(sequence == [.inProcess, .inProcess, .relay, .relay, .inProcess])
    }
}
