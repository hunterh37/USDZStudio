import Foundation
import USDCore

/// Pure animation-transport state (specs/viewport.md §Animation Playback):
/// current time, the authored time-code range, play/pause, loop, and playback
/// speed. RealityKit drives its `AnimationResource` from `currentTime`; this
/// value type owns the advance / loop / clamp / scrub math so it is unit-testable
/// without a rendering host ("deterministic sampled-pose frames" — ROADMAP
/// Milestone 2 exit).
///
/// Time is measured in **time codes** (USD's authored unit). `timeCodesPerSecond`
/// converts wall-clock seconds into time codes so playback runs at the authored
/// rate; `rate` is an additional user speed multiplier (0.5×, 2×, …).
public struct PlaybackTransport: Hashable, Sendable {

    /// Inclusive authored time-code range.
    public var startTime: Double
    public var endTime: Double
    /// Playhead, always kept within `[startTime, endTime]`.
    public private(set) var currentTime: Double
    public var isPlaying: Bool
    public var isLooping: Bool
    /// User speed multiplier (1 = authored speed). May be negative for reverse.
    public var rate: Double
    /// Authored playback rate (frames / codes per wall-clock second).
    public var timeCodesPerSecond: Double

    /// Speed presets the transport UI offers.
    public static let ratePresets: [Double] = [0.25, 0.5, 1, 2, 4]

    public init(
        startTime: Double = 0,
        endTime: Double = 0,
        currentTime: Double = 0,
        isPlaying: Bool = false,
        isLooping: Bool = false,
        rate: Double = 1,
        timeCodesPerSecond: Double = 24
    ) {
        // Tolerate a reversed range by normalising it.
        let lo = min(startTime, endTime)
        let hi = max(startTime, endTime)
        self.startTime = lo
        self.endTime = hi
        self.isPlaying = isPlaying
        self.isLooping = isLooping
        self.rate = rate
        self.timeCodesPerSecond = timeCodesPerSecond > 0 ? timeCodesPerSecond : 24
        self.currentTime = Self.clamp(currentTime, lo: lo, hi: hi)
    }

    /// Builds a transport from a stage's root metadata, or `nil` when the stage
    /// carries no authored animation range (the transport bar stays hidden).
    public init?(metadata: StageMetadata) {
        guard let start = metadata.startTimeCode, let end = metadata.endTimeCode else {
            return nil
        }
        self.init(
            startTime: start,
            endTime: end,
            currentTime: start,
            timeCodesPerSecond: metadata.timeCodesPerSecond ?? 24
        )
    }

    // MARK: Derived

    /// Length of the authored range in time codes (never negative).
    public var duration: Double { endTime - startTime }

    /// `true` when the range spans more than a single instant.
    public var hasRange: Bool { duration > 0 }

    /// Playhead position in `[0, 1]` across the range (0 for an empty range).
    public var progress: Double {
        guard hasRange else { return 0 }
        return (currentTime - startTime) / duration
    }

    /// Frame index of the playhead (time codes are USD frame numbers).
    public var currentFrame: Int { Int(currentTime.rounded()) }

    /// First / last authored frame numbers (for the transport's frame counter).
    public var startFrame: Int { Int(startTime.rounded()) }
    public var endFrame: Int { Int(endTime.rounded()) }

    /// Total number of whole frames in the range (at least 1).
    public var frameCount: Int { max(1, Int(duration.rounded()) + 1) }

    /// `true` once a forward playthrough reaches the end (or a reverse one the
    /// start) — the transport parks there when not looping.
    public var isAtEnd: Bool { currentTime >= endTime }
    public var isAtStart: Bool { currentTime <= startTime }

    // MARK: Advance

    /// Advances the playhead by `seconds` of wall-clock time when playing.
    /// Loops wrap the playhead back into the range (in either direction);
    /// otherwise the playhead clamps to the boundary and playback stops.
    public mutating func advance(bySeconds seconds: Double) {
        guard isPlaying, hasRange, seconds != 0 else { return }
        let deltaCodes = seconds * rate * timeCodesPerSecond
        guard deltaCodes != 0 else { return }
        let proposed = currentTime + deltaCodes
        if proposed > endTime {
            if isLooping {
                currentTime = Self.wrap(proposed, start: startTime, end: endTime)
            } else {
                currentTime = endTime
                isPlaying = false
            }
        } else if proposed < startTime {
            if isLooping {
                currentTime = Self.wrap(proposed, start: startTime, end: endTime)
            } else {
                currentTime = startTime
                isPlaying = false
            }
        } else {
            currentTime = proposed
        }
    }

    // MARK: Intents

    /// Play/pause toggle. Starting a stopped-at-end forward transport (or a
    /// stopped-at-start reverse one) rewinds to the opposite boundary first, so
    /// the button always produces motion.
    public mutating func togglePlay() {
        if isPlaying {
            isPlaying = false
        } else {
            if hasRange {
                if rate >= 0, isAtEnd { currentTime = startTime }
                else if rate < 0, isAtStart { currentTime = endTime }
            }
            isPlaying = true
        }
    }

    public mutating func pause() { isPlaying = false }

    /// Moves the playhead to an absolute time code (clamped). Scrubbing does not
    /// change the play state — the spec's scrub while playing keeps playing.
    public mutating func scrub(to time: Double) {
        currentTime = Self.clamp(time, lo: startTime, hi: endTime)
    }

    /// Moves the playhead to a `[0, 1]` position across the range.
    public mutating func scrub(toProgress p: Double) {
        scrub(to: startTime + Self.clamp(p, lo: 0, hi: 1) * duration)
    }

    /// Nudges the playhead by whole frames (time codes); pauses playback so the
    /// user can inspect a single frame.
    public mutating func stepFrame(_ delta: Int) {
        isPlaying = false
        scrub(to: currentTime + Double(delta))
    }

    public mutating func seekToStart() { scrub(to: startTime) }
    public mutating func seekToEnd() { scrub(to: endTime) }

    // MARK: Math

    static func clamp(_ v: Double, lo: Double, hi: Double) -> Double {
        guard hi > lo else { return lo }
        return min(max(v, lo), hi)
    }

    /// Wraps `t` into `[start, end)` (used for looping), handling multiple laps
    /// and negative overshoot.
    static func wrap(_ t: Double, start: Double, end: Double) -> Double {
        let span = end - start
        guard span > 0 else { return start }
        var r = (t - start).truncatingRemainder(dividingBy: span)
        if r < 0 { r += span }
        return start + r
    }
}
