import Foundation

/// A single invokable editor action, described purely as data so the same
/// definition can back a menu item, a keyboard shortcut, and a command-palette
/// row (specs/command-palette.md — "menu/shortcut/palette unification"). The
/// behaviour (the closure that actually runs) is paired with this descriptor by
/// `PaletteAction`; keeping the metadata a plain `Sendable` value keeps the
/// registry and its ranking provable without a running UI.
public struct ActionItem: Identifiable, Hashable, Sendable {
    /// Stable identifier, unique within a registry. Used to look the action's
    /// closure back up after the (value-type) registry ranks it.
    public let id: String
    /// Human-facing command name, e.g. "Save As…". Primary match target.
    public let title: String
    /// Grouping label shown as a trailing hint, e.g. "File", "Convert".
    public let category: String
    /// Display string for the bound shortcut, e.g. "⌘S" (nil when unbound).
    public let shortcut: String?
    /// Extra search terms that don't appear in the title (e.g. "quit", synonyms).
    public let keywords: [String]
    /// Whether the action can run in the current context. Disabled actions still
    /// appear (greyed, sorted last) so the palette mirrors the menu exactly.
    public let isEnabled: Bool

    public init(id: String,
                title: String,
                category: String,
                shortcut: String? = nil,
                keywords: [String] = [],
                isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.keywords = keywords
        self.isEnabled = isEnabled
    }
}

/// Case-insensitive subsequence fuzzy matcher. Deterministic and side-effect
/// free so its scoring is unit-tested exhaustively. A query matches a candidate
/// when every query character appears, in order, somewhere in the candidate;
/// the score rewards matches that are consecutive, at word boundaries, and at
/// the very start — the standard "camelCase / space / kebab" heuristics that
/// make `sa` rank "Save" above "Isolate Selection".
public enum FuzzyMatcher {
    /// Returns a match score (higher is better), or nil when `query` is not a
    /// subsequence of `candidate`. An empty query trivially matches with score 0.
    public static func score(query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let lower = Array(candidate.lowercased())
        let original = Array(candidate)

        var qi = 0
        var total = 0
        var previousMatched = false
        var i = 0
        while i < lower.count && qi < q.count {
            if lower[i] == q[qi] {
                var s = 1
                if previousMatched { s += 3 }          // consecutive run
                if isWordBoundary(original, i) { s += 5 } // start of a word
                if i == 0 { s += 2 }                    // very first character
                total += s
                qi += 1
                previousMatched = true
            } else {
                previousMatched = false
            }
            i += 1
        }
        return qi == q.count ? total : nil
    }

    /// A boundary is index 0, a character right after a separator, or the
    /// uppercase half of a camelCase hump.
    static func isWordBoundary(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        if prev == " " || prev == "-" || prev == "_" || prev == "/" { return true }
        return chars[i].isUppercase && prev.isLowercase
    }
}

/// A ranked, searchable set of `ActionItem`s. Pure value type: `search` is a
/// deterministic ranking function with no UI or global state, which is what
/// lets the palette's behaviour be verified without rendering anything.
public struct ActionRegistry: Sendable {
    public let items: [ActionItem]

    public init(_ items: [ActionItem]) {
        self.items = items
    }

    /// Ranked matches for `query`. An empty/whitespace query returns every item
    /// in a stable default order (enabled first, then by category then title).
    /// Otherwise items are scored, non-matches dropped, and the rest ordered by
    /// (enabled first, higher score, then title) — a total order, so the result
    /// is deterministic even when scores tie.
    public func search(_ query: String) -> [ActionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return items.sorted(by: Self.defaultOrder)
        }
        var scored: [(item: ActionItem, score: Int)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            if let s = bestScore(for: item, query: trimmed) {
                scored.append((item, s))
            }
        }
        return scored.sorted { a, b in
            if a.item.isEnabled != b.item.isEnabled { return a.item.isEnabled }
            if a.score != b.score { return a.score > b.score }
            return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
        }.map(\.item)
    }

    /// Best score across the fields we match, with the title weighted above
    /// keywords/category so a title hit outranks an incidental keyword hit.
    private func bestScore(for item: ActionItem, query: String) -> Int? {
        var best: Int?
        func consider(_ candidate: String, weight: Int) {
            guard let s = FuzzyMatcher.score(query: query, in: candidate) else { return }
            let total = s + weight
            if best == nil || total > best! { best = total }
        }
        consider(item.title, weight: 10)
        for keyword in item.keywords { consider(keyword, weight: 0) }
        consider(item.category, weight: 0)
        return best
    }

    /// Stable ordering for the no-query case.
    static func defaultOrder(_ a: ActionItem, _ b: ActionItem) -> Bool {
        if a.isEnabled != b.isEnabled { return a.isEnabled }
        if a.category != b.category {
            return a.category.localizedCaseInsensitiveCompare(b.category) == .orderedAscending
        }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}
