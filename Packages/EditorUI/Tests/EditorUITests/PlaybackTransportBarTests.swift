import Testing
import Foundation
import SwiftUI
import USDCore
import ViewportKit
@testable import EditorUI

@MainActor
@Suite struct PlaybackControllerTests {

    private func animatedMetadata(start: Double = 0, end: Double = 48,
                                  tcps: Double = 24) -> StageMetadata {
        var m = StageMetadata()
        m.startTimeCode = start
        m.endTimeCode = end
        m.timeCodesPerSecond = tcps
        return m
    }

    @Test func configureWithAnimationBecomesAvailable() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata())
        #expect(c.isAvailable)
        #expect(c.transport.startTime == 0)
        #expect(c.transport.endTime == 48)
        #expect(c.animationTime == 0)
    }

    @Test func configureWithoutAnimationIsUnavailable() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata())
        c.configure(from: StageMetadata())
        #expect(!c.isAvailable)
        #expect(c.animationTime == nil)
    }

    @Test func configureWithNilMetadataIsUnavailable() {
        let c = PlaybackController()
        c.configure(from: nil)
        #expect(!c.isAvailable)
    }

    @Test func animationTimeConvertsCodesToSeconds() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 24, end: 72, tcps: 24))
        // Playhead at start → 0s; scrub to halfway (frame 48) → 1s past start.
        #expect(c.animationTime == 0)
        c.scrub(toProgress: 0.5)
        #expect(c.animationTime == 1)
    }

    @Test func tickAdvancesWhenPlaying() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 240, tcps: 24))
        c.togglePlay()
        let t0 = Date()
        c.tick(at: t0)               // establishes the clock, no motion
        #expect(c.transport.currentTime == 0)
        c.tick(at: t0.addingTimeInterval(0.05)) // +0.05s → +1.2 codes (under the cap)
        #expect(abs(c.transport.currentTime - 1.2) < 1e-4)
    }

    @Test func tickWhilePausedOnlyUpdatesClock() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 240))
        let t0 = Date()
        c.tick(at: t0)
        c.tick(at: t0.addingTimeInterval(1))
        #expect(c.transport.currentTime == 0)
    }

    @Test func tickIgnoresNonPositiveDelta() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 240))
        c.togglePlay()
        let t0 = Date()
        c.tick(at: t0)
        c.tick(at: t0)               // same instant → dt == 0
        #expect(c.transport.currentTime == 0)
    }

    @Test func tickCapsLargeGaps() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 2400, tcps: 24))
        c.togglePlay()
        let t0 = Date()
        c.tick(at: t0)
        c.tick(at: t0.addingTimeInterval(100)) // huge gap, capped to 0.1s → 2.4 codes
        #expect(abs(c.transport.currentTime - 2.4) < 1e-4)
    }

    @Test func tickDoesNothingWhenUnavailable() {
        let c = PlaybackController()
        c.tick(at: Date())
        #expect(c.transport.currentTime == 0)
    }

    @Test func togglePlayResetsTickClock() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 240))
        c.togglePlay()
        #expect(c.transport.isPlaying)
        // After a toggle the first tick establishes the clock again (no jump).
        c.tick(at: Date().addingTimeInterval(5))
        #expect(c.transport.currentTime == 0)
    }

    @Test func intentsForwardToTransport() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 48))
        c.setLooping(true)
        #expect(c.transport.isLooping)
        c.setRate(2)
        #expect(c.transport.rate == 2)
        c.scrub(toProgress: 1)
        #expect(c.transport.currentTime == 48)
        c.stepFrame(-1)
        #expect(c.transport.currentTime == 47)
        c.seekToStart()
        #expect(c.transport.currentTime == 0)
    }

    @Test func frameLabelReflectsPlayhead() {
        let c = PlaybackController()
        c.configure(from: animatedMetadata(start: 0, end: 48))
        #expect(c.frameLabel == "0 / 48")
        c.scrub(toProgress: 0.5)
        #expect(c.frameLabel == "24 / 48")
    }
}

@MainActor
@Suite struct PlaybackTransportBarViewTests {

    @Test func barBodyRendersAllStates() {
        let c = PlaybackController()
        var m = StageMetadata()
        m.startTimeCode = 0
        m.endTimeCode = 48
        m.timeCodesPerSecond = 24
        c.configure(from: m)
        _ = PlaybackTransportBar(controller: c).body
        c.togglePlay()          // exercise the playing glyph branch
        c.setLooping(true)
        c.setRate(0.5)
        _ = PlaybackTransportBar(controller: c).body
    }

    @Test func rateLabelTrimsWholeNumbers() {
        #expect(PlaybackTransportBar.rateLabel(1) == "1×")
        #expect(PlaybackTransportBar.rateLabel(2) == "2×")
        #expect(PlaybackTransportBar.rateLabel(0.5) == "0.5×")
    }
}
