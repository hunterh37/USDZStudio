import SwiftUI
import USDCore
import ViewportKit
import DicyaninDesignSystem

/// Observable playback state for the viewport transport (specs/viewport.md
/// §Animation Playback). Wraps the pure `PlaybackTransport` value type from
/// ViewportKit: the intent methods forward to it, and `tick(at:)` advances it
/// from the SwiftUI display link. Kept as a thin, testable seam so the transport
/// math stays in ViewportKit and the UI stays declarative.
@MainActor
@Observable
public final class PlaybackController {

    /// The pure transport state driving the playhead.
    public private(set) var transport = PlaybackTransport()
    /// `true` when the open stage declares an animation range — the transport
    /// bar auto-hides when this is `false`.
    public private(set) var isAvailable = false

    /// Wall-clock timestamp of the previous tick, used to compute a delta. Reset
    /// whenever motion should not accumulate across the gap (pause, scrub, reload).
    private var lastTick: Date?

    public init() {}

    /// Reconfigures from a stage's root metadata (or clears when the stage has no
    /// authored animation range). Resets the playhead to the clip start.
    public func configure(from metadata: StageMetadata?) {
        if let metadata, let transport = PlaybackTransport(metadata: metadata) {
            self.transport = transport
            isAvailable = true
        } else {
            transport = PlaybackTransport()
            isAvailable = false
        }
        lastTick = nil
    }

    /// Playhead in seconds from the clip start, for the viewport to seek to;
    /// `nil` when no animation is available (model rests at its default pose).
    public var animationTime: Double? {
        guard isAvailable else { return nil }
        return (transport.currentTime - transport.startTime) / transport.timeCodesPerSecond
    }

    /// Frame-counter label ("12 / 48") for the transport bar.
    public var frameLabel: String {
        "\(transport.currentFrame) / \(transport.endFrame)"
    }

    /// Advances the playhead by the wall-clock delta since the last tick. A large
    /// gap (window occluded, debugger paused) is capped so playback resumes
    /// smoothly instead of jumping.
    public func tick(at date: Date) {
        guard isAvailable, transport.isPlaying else {
            lastTick = date
            return
        }
        defer { lastTick = date }
        guard let last = lastTick else { return }
        let dt = date.timeIntervalSince(last)
        guard dt > 0 else { return }
        transport.advance(bySeconds: min(dt, 0.1))
    }

    // MARK: Intents (forward to the value type; reset the tick clock as needed)

    public func togglePlay() {
        transport.togglePlay()
        lastTick = nil
    }

    public func scrub(toProgress p: Double) { transport.scrub(toProgress: p) }
    public func setLooping(_ v: Bool) { transport.isLooping = v }
    public func setRate(_ r: Double) { transport.rate = r }

    public func stepFrame(_ delta: Int) {
        transport.stepFrame(delta)
        lastTick = nil
    }

    public func seekToStart() {
        transport.seekToStart()
        lastTick = nil
    }
}

/// The transport bar pinned to the bottom of the viewport: play/pause, scrub
/// slider, loop toggle, speed menu, and a frame counter honouring the stage's
/// `timeCodesPerSecond` (specs/viewport.md §Animation Playback). Auto-hidden by
/// the caller when `controller.isAvailable` is false.
struct PlaybackTransportBar: View {

    @Bindable var controller: PlaybackController

    /// ~60fps display link driving `tick`. Ticking while paused is harmless (the
    /// controller just refreshes its clock reference).
    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let transport = controller.transport
        HStack(spacing: 10) {
            Button(action: controller.seekToStart) {
                Image(systemName: "backward.end.fill")
            }
            .help("Jump to start")

            Button(action: { controller.stepFrame(-1) }) {
                Image(systemName: "backward.frame.fill")
            }
            .help("Previous frame")

            Button(action: controller.togglePlay) {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .help(transport.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])

            Button(action: { controller.stepFrame(1) }) {
                Image(systemName: "forward.frame.fill")
            }
            .help("Next frame")

            Slider(
                value: Binding(get: { transport.progress },
                               set: { controller.scrub(toProgress: $0) }),
                in: 0...1)
                .controlSize(.small)

            Text(controller.frameLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)

            Toggle(isOn: Binding(get: { transport.isLooping },
                                 set: { controller.setLooping($0) })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop")

            Menu {
                ForEach(PlaybackTransport.ratePresets, id: \.self) { rate in
                    Button {
                        controller.setRate(rate)
                    } label: {
                        Label(Self.rateLabel(rate),
                              systemImage: transport.rate == rate ? "checkmark" : "")
                    }
                }
            } label: {
                Text(Self.rateLabel(transport.rate))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 34)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .onReceive(ticker) { controller.tick(at: $0) }
    }

    /// "1×", "0.5×" — trims a trailing ".0" so whole speeds read cleanly.
    static func rateLabel(_ rate: Double) -> String {
        let s = rate == rate.rounded() ? String(Int(rate)) : String(rate)
        return "\(s)×"
    }
}
