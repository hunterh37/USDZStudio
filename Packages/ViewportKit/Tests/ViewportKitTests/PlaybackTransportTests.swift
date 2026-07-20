import Testing
import USDCore
@testable import ViewportKit

@Suite struct PlaybackTransportTests {

    // MARK: Init & normalisation

    @Test func initClampsCurrentTimeIntoRange() {
        let below = PlaybackTransport(startTime: 10, endTime: 20, currentTime: 5)
        #expect(below.currentTime == 10)
        let above = PlaybackTransport(startTime: 10, endTime: 20, currentTime: 99)
        #expect(above.currentTime == 20)
        let inside = PlaybackTransport(startTime: 10, endTime: 20, currentTime: 15)
        #expect(inside.currentTime == 15)
    }

    @Test func initNormalisesReversedRange() {
        let t = PlaybackTransport(startTime: 20, endTime: 5, currentTime: 10)
        #expect(t.startTime == 5)
        #expect(t.endTime == 20)
        #expect(t.currentTime == 10)
    }

    @Test func initRejectsNonPositiveTimeCodesPerSecond() {
        #expect(PlaybackTransport(timeCodesPerSecond: 0).timeCodesPerSecond == 24)
        #expect(PlaybackTransport(timeCodesPerSecond: -5).timeCodesPerSecond == 24)
        #expect(PlaybackTransport(timeCodesPerSecond: 30).timeCodesPerSecond == 30)
    }

    @Test func metadataInitReturnsNilWithoutRange() {
        #expect(PlaybackTransport(metadata: StageMetadata()) == nil)
        var partial = StageMetadata()
        partial.startTimeCode = 0
        #expect(PlaybackTransport(metadata: partial) == nil)
    }

    @Test func metadataInitBuildsTransportFromRange() {
        var m = StageMetadata()
        m.startTimeCode = 1
        m.endTimeCode = 25
        m.timeCodesPerSecond = 30
        let t = PlaybackTransport(metadata: m)
        #expect(t?.startTime == 1)
        #expect(t?.endTime == 25)
        #expect(t?.currentTime == 1)
        #expect(t?.timeCodesPerSecond == 30)
    }

    @Test func metadataInitDefaultsTimeCodesPerSecond() {
        var m = StageMetadata()
        m.startTimeCode = 0
        m.endTimeCode = 10
        #expect(PlaybackTransport(metadata: m)?.timeCodesPerSecond == 24)
    }

    // MARK: Derived

    @Test func derivedRangeQuantities() {
        let t = PlaybackTransport(startTime: 0, endTime: 48, currentTime: 12,
                                  timeCodesPerSecond: 24)
        #expect(t.duration == 48)
        #expect(t.hasRange)
        #expect(t.progress == 0.25)
        #expect(t.currentFrame == 12)
        #expect(t.frameCount == 49)
        #expect(t.startFrame == 0)
        #expect(t.endFrame == 48)
    }

    @Test func emptyRangeHasNoProgress() {
        let t = PlaybackTransport(startTime: 5, endTime: 5)
        #expect(!t.hasRange)
        #expect(t.progress == 0)
        #expect(t.frameCount == 1)
    }

    @Test func boundaryFlags() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 0)
        #expect(t.isAtStart)
        #expect(!t.isAtEnd)
        t.scrub(to: 10)
        #expect(t.isAtEnd)
        #expect(!t.isAtStart)
    }

    // MARK: Advance — clamp/stop

    @Test func advanceMovesPlayheadWhenPlaying() {
        var t = PlaybackTransport(startTime: 0, endTime: 24, currentTime: 0,
                                  isPlaying: true, timeCodesPerSecond: 24)
        t.advance(bySeconds: 0.5) // 12 codes
        #expect(t.currentTime == 12)
        #expect(t.isPlaying)
    }

    @Test func advanceDoesNothingWhenPaused() {
        var t = PlaybackTransport(startTime: 0, endTime: 24, currentTime: 3,
                                  isPlaying: false)
        t.advance(bySeconds: 1)
        #expect(t.currentTime == 3)
    }

    @Test func advanceIgnoresZeroDelta() {
        var t = PlaybackTransport(startTime: 0, endTime: 24, currentTime: 3,
                                  isPlaying: true)
        t.advance(bySeconds: 0)
        #expect(t.currentTime == 3)
        var z = PlaybackTransport(startTime: 0, endTime: 24, currentTime: 3,
                                  isPlaying: true, rate: 0)
        z.advance(bySeconds: 1)
        #expect(z.currentTime == 3)
    }

    @Test func advanceDoesNothingWithoutRange() {
        var t = PlaybackTransport(startTime: 4, endTime: 4, currentTime: 4,
                                  isPlaying: true)
        t.advance(bySeconds: 1)
        #expect(t.currentTime == 4)
    }

    @Test func nonLoopingForwardClampsAndStopsAtEnd() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 8,
                                  isPlaying: true, isLooping: false,
                                  timeCodesPerSecond: 24)
        t.advance(bySeconds: 1) // overshoots
        #expect(t.currentTime == 10)
        #expect(!t.isPlaying)
    }

    @Test func nonLoopingReverseClampsAndStopsAtStart() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 2,
                                  isPlaying: true, isLooping: false,
                                  rate: -1, timeCodesPerSecond: 24)
        t.advance(bySeconds: 1)
        #expect(t.currentTime == 0)
        #expect(!t.isPlaying)
    }

    // MARK: Advance — loop

    @Test func loopingForwardWrapsAroundEnd() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 8,
                                  isPlaying: true, isLooping: true,
                                  timeCodesPerSecond: 24)
        t.advance(bySeconds: 0.25) // +6 codes → 14 → wraps to 4
        #expect(t.currentTime == 4)
        #expect(t.isPlaying)
    }

    @Test func loopingReverseWrapsAroundStart() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 2,
                                  isPlaying: true, isLooping: true,
                                  rate: -1, timeCodesPerSecond: 24)
        t.advance(bySeconds: 0.25) // -6 → -4 → wraps to 6
        #expect(t.currentTime == 6)
        #expect(t.isPlaying)
    }

    @Test func loopingHandlesMultipleLaps() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 0,
                                  isPlaying: true, isLooping: true,
                                  timeCodesPerSecond: 24)
        t.advance(bySeconds: 1) // +24 codes over span 10 → 24 % 10 = 4
        #expect(t.currentTime == 4)
    }

    // MARK: Intents

    @Test func togglePlayFlips() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 3)
        t.togglePlay()
        #expect(t.isPlaying)
        t.togglePlay()
        #expect(!t.isPlaying)
    }

    @Test func togglePlayFromEndRewindsForward() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 10)
        t.togglePlay()
        #expect(t.isPlaying)
        #expect(t.currentTime == 0)
    }

    @Test func togglePlayFromStartRewindsReverse() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 0, rate: -1)
        t.togglePlay()
        #expect(t.isPlaying)
        #expect(t.currentTime == 10)
    }

    @Test func pauseStops() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 3, isPlaying: true)
        t.pause()
        #expect(!t.isPlaying)
    }

    @Test func scrubClampsWithoutChangingPlayState() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 3, isPlaying: true)
        t.scrub(to: 99)
        #expect(t.currentTime == 10)
        #expect(t.isPlaying)
        t.scrub(to: -5)
        #expect(t.currentTime == 0)
    }

    @Test func scrubToProgressMapsAndClamps() {
        var t = PlaybackTransport(startTime: 10, endTime: 30)
        t.scrub(toProgress: 0.5)
        #expect(t.currentTime == 20)
        t.scrub(toProgress: 2)
        #expect(t.currentTime == 30)
        t.scrub(toProgress: -1)
        #expect(t.currentTime == 10)
    }

    @Test func stepFramePausesAndNudges() {
        var t = PlaybackTransport(startTime: 0, endTime: 10, currentTime: 3, isPlaying: true)
        t.stepFrame(2)
        #expect(t.currentTime == 5)
        #expect(!t.isPlaying)
        t.stepFrame(-1)
        #expect(t.currentTime == 4)
    }

    @Test func seekHelpers() {
        var t = PlaybackTransport(startTime: 2, endTime: 8, currentTime: 5)
        t.seekToEnd()
        #expect(t.currentTime == 8)
        t.seekToStart()
        #expect(t.currentTime == 2)
    }

    // MARK: Math helpers

    @Test func clampDegenerateRangeReturnsLow() {
        #expect(PlaybackTransport.clamp(5, lo: 3, hi: 3) == 3)
    }

    @Test func wrapDegenerateSpanReturnsStart() {
        #expect(PlaybackTransport.wrap(99, start: 4, end: 4) == 4)
    }

    @Test func ratePresetsExposed() {
        #expect(PlaybackTransport.ratePresets.contains(1))
    }
}
