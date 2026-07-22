import Foundation

/// Namespace for a breadcrumb ("app.lifecycle", "edit.command", …).
///
/// A struct over a raw string — not an enum — so adding a new category is one
/// `static let` in any adopting module, with no source-breaking enum churn and
/// no decode failures when an older build reads a newer log.
public struct BreadcrumbCategory: RawRepresentable, Hashable, Codable, Sendable,
                                  ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    /// App launch / terminate / scene-phase transitions.
    public static let lifecycle: Self = "app.lifecycle"
    /// Undoable edit commands (run / undo / redo).
    public static let command: Self = "edit.command"
    /// User-facing UI actions (menus, shortcuts, palette).
    public static let action: Self = "ui.action"
    /// Agent MCP session / tool activity.
    public static let mcp: Self = "agent.mcp"
    /// Crash detection: prior-session unclean-exit reports.
    public static let crash: Self = "crash"
}

/// Severity of a breadcrumb. Ordering matters: the logger flushes immediately
/// at or above a configurable threshold (default `.warning`).
public enum BreadcrumbLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, warning, error, fault

    /// Rank used for `Comparable`; follows `allCases` declaration order.
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// One line in a session log. Encoded as JSON Lines (one object per line), the
/// same crash-tolerant discipline as `EditingKit`'s WAL: a torn final line is
/// discarded on read, every complete line before it survives.
public struct Breadcrumb: Codable, Equatable, Sendable {
    /// Monotonic per session, assigned by `BreadcrumbLogger` in call order —
    /// disambiguates ordering when wall-clock timestamps collide.
    public let seq: UInt64
    /// Wall-clock time the breadcrumb was logged.
    public let timestamp: Date
    public let category: BreadcrumbCategory
    public let level: BreadcrumbLevel
    public let message: String
    /// Flat string-to-string payload. Deliberately not `Any`/`AnyCodable`:
    /// keeps the record `Codable + Sendable` with zero dependency risk.
    public let metadata: [String: String]

    public init(seq: UInt64, timestamp: Date, category: BreadcrumbCategory,
                level: BreadcrumbLevel, message: String, metadata: [String: String] = [:]) {
        self.seq = seq
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}
