import Foundation

/// A one-shot request to frame the camera on a single prim (double-clicking an
/// outliner row — specs/viewport.md "Framing").
///
/// The viewport is a value-driven SwiftUI view, so "do this once" has to be
/// expressed as state that *changes*: the host bumps `token` for every request
/// and the coordinator re-frames only when the token it last honoured differs.
/// That makes framing the same prim twice in a row work, which a plain
/// `path`-only property could not express.
public struct FramePrimRequest: Equatable, Sendable {
    /// Absolute prim path to frame; `nil` frames the whole model (the `F` key).
    public var path: String?
    /// Monotonic request counter — see the type doc.
    public var token: Int

    public init(path: String?, token: Int) {
        self.path = path
        self.token = token
    }

    /// The successor request for `path`, continuing this request's token
    /// sequence. `nil` (no previous request) starts the sequence at 1.
    public static func next(after previous: FramePrimRequest?, path: String?) -> FramePrimRequest {
        FramePrimRequest(path: path, token: (previous?.token ?? 0) + 1)
    }

    /// Whether the coordinator should act on this request given the last one it
    /// honoured. Only a *new* token fires; re-delivery of the same request (any
    /// unrelated SwiftUI update re-runs `updateNSView`) must not re-frame, or
    /// the camera would snap back while the user orbits.
    public func shouldApply(lastApplied: FramePrimRequest?) -> Bool {
        token != lastApplied?.token
    }
}
