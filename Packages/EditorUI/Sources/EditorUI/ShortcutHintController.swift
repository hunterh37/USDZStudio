import Foundation
import Observation

/// The suppressible "don't show hints again" preference, injected so the
/// controller is testable without `UserDefaults`. `EditorSettings` conforms.
@MainActor
public protocol HintPreferenceStore: AnyObject {
    var showHotkeyHints: Bool { get set }
}

/// Pure decision logic for the transient shortcut-hint toast: fade-in on scene
/// appear → hold → auto-fade, dismiss-on-interaction, once-per-session, and a
/// persisted "don't show" suppression. Only the opacity *animation* is
/// view-side; every show/hold/fade/gate decision lives here and is unit-tested
/// with an explicit clock (times are passed in, no real timers).
@Observable
@MainActor
public final class ShortcutHintController {

    /// Which phase of the show/hold/fade cycle the toast is in.
    public enum Phase: Equatable, Sendable { case hidden, fadingIn, holding, fadingOut }

    // Timing (seconds). Fade-in ~0.4, hold ~4, fade-out ~0.6 per plan.
    public static let fadeIn: TimeInterval = 0.4
    public static let hold: TimeInterval = 4.0
    public static let fadeOut: TimeInterval = 0.6
    private static var total: TimeInterval { fadeIn + hold + fadeOut }

    public private(set) var phase: Phase = .hidden
    public private(set) var opacity: Double = 0

    /// The essentials line the toast renders (from the registry).
    public let text = ShortcutRegistry.hintLine

    /// When the current cycle started; `nil` when idle/hidden.
    @ObservationIgnored private var startTime: TimeInterval?
    /// Once-per-document-open gate: the toast shows at most once per session.
    @ObservationIgnored private var shownThisSession = false

    @ObservationIgnored private let preferences: HintPreferenceStore?

    public init(preferences: HintPreferenceStore? = nil) {
        self.preferences = preferences
    }

    /// Whether the toast is currently drawn.
    public var isVisible: Bool { phase != .hidden }

    /// Whether the user has suppressed hints (pref off).
    private var suppressed: Bool { preferences?.showHotkeyHints == false }

    /// A scene became visible in the viewport. Starts the cycle unless it has
    /// already run this session or the user suppressed hints.
    public func onSceneAppear(now: TimeInterval) {
        guard !shownThisSession, !suppressed else { return }
        shownThisSession = true
        startTime = now
        phase = .fadingIn
        opacity = 0
    }

    /// Any viewport interaction dismisses the toast early.
    public func onInteraction() {
        guard isVisible else { return }
        startTime = nil
        phase = .hidden
        opacity = 0
    }

    /// Advances the animation to `now`, updating `phase`/`opacity`. A no-op once
    /// hidden. The view calls this from its display loop; tests call it directly.
    public func tick(now: TimeInterval) {
        guard let start = startTime else { return }
        let t = now - start
        switch t {
        case ..<0:
            opacity = 0; phase = .fadingIn
        case ..<Self.fadeIn:
            opacity = min(1, max(0, t / Self.fadeIn)); phase = .fadingIn
        case ..<(Self.fadeIn + Self.hold):
            opacity = 1; phase = .holding
        case ..<Self.total:
            let into = t - Self.fadeIn - Self.hold
            opacity = min(1, max(0, 1 - into / Self.fadeOut)); phase = .fadingOut
        default:
            opacity = 0; phase = .hidden; startTime = nil
        }
    }

    /// Suppresses hints for good ("Don't show hints" affordance) and hides the
    /// toast now.
    public func dismissForever() {
        preferences?.showHotkeyHints = false
        onInteraction()
    }

    /// Test/utility hook: forget the once-per-session gate (e.g. a new document
    /// opened in the same window).
    public func resetSession() {
        shownThisSession = false
        onInteraction()
    }
}
