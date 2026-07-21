import Foundation

/// Errors raised by the session persistence layer.
///
/// These are deliberately few: session restoration must *never* be able to
/// block launch, so `SessionStore` treats every failure as "no session to
/// restore" and degrades to a clean start. The typed cases exist so callers
/// (and tests) can distinguish a genuinely absent session from a corrupt one.
public enum SessionError: Error, Equatable, Sendable {
    /// The stored `session.json` exists but could not be decoded — a truncated
    /// or hand-mangled file. The store drops it and starts fresh.
    case corruptState
    /// A file attribute needed for a source fingerprint could not be read.
    case unreadableSource
}
