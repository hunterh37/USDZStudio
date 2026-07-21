import Testing
@testable import EditorUI

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    @Test("empty query matches anything with score zero")
    func emptyQuery() {
        #expect(FuzzyMatcher.score(query: "", in: "Save As…") == 0)
        #expect(FuzzyMatcher.score(query: "", in: "") == 0)
    }

    @Test("non-subsequence returns nil")
    func noMatch() {
        #expect(FuzzyMatcher.score(query: "zzz", in: "Save") == nil)
        // Out-of-order characters are not a subsequence.
        #expect(FuzzyMatcher.score(query: "eas", in: "Save") == nil)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(FuzzyMatcher.score(query: "SAVE", in: "save") != nil)
        #expect(FuzzyMatcher.score(query: "save", in: "SAVE") != nil)
    }

    @Test("prefix at the very start scores higher than a mid-word match")
    func startBonus() {
        let start = FuzzyMatcher.score(query: "sa", in: "Save")!
        let mid = FuzzyMatcher.score(query: "sa", in: "Isolate")! // 'S'? no — matches 's','a' inside 'iSolAte'
        #expect(start > mid)
    }

    @Test("consecutive characters beat scattered ones (boundaries held equal)")
    func consecutiveBonus() {
        // Both 'b' and 'c' are mid-word (non-boundary) in each candidate, so the
        // only difference is adjacency: "abcd" matches "bc" consecutively while
        // "abxc" does not.
        let consecutive = FuzzyMatcher.score(query: "bc", in: "abcd")!
        let scattered = FuzzyMatcher.score(query: "bc", in: "abxc")!
        #expect(consecutive > scattered)
    }

    @Test("word-boundary detection across separators and camelCase")
    func boundaries() {
        #expect(FuzzyMatcher.isWordBoundary(Array("Save"), 0) == true)
        #expect(FuzzyMatcher.isWordBoundary(Array("Save As"), 5) == true)   // after space
        #expect(FuzzyMatcher.isWordBoundary(Array("save-as"), 5) == true)   // after hyphen
        #expect(FuzzyMatcher.isWordBoundary(Array("save_as"), 5) == true)   // after underscore
        #expect(FuzzyMatcher.isWordBoundary(Array("a/b"), 2) == true)       // after slash
        #expect(FuzzyMatcher.isWordBoundary(Array("camelCase"), 5) == true) // C after l
        #expect(FuzzyMatcher.isWordBoundary(Array("save"), 1) == false)     // mid-word
    }
}

@Suite("ActionRegistry")
struct ActionRegistryTests {

    private func registry() -> ActionRegistry {
        ActionRegistry([
            ActionItem(id: "save", title: "Save", category: "File", shortcut: "⌘S"),
            ActionItem(id: "saveAs", title: "Save As…", category: "File", shortcut: "⇧⌘S"),
            ActionItem(id: "export", title: "Export…", category: "File", keywords: ["usdz", "share"]),
            ActionItem(id: "undo", title: "Undo", category: "Edit", isEnabled: false),
            ActionItem(id: "validate", title: "Validate Stage", category: "View"),
        ])
    }

    @Test("empty query returns every item, enabled first then category/title")
    func emptyQueryDefaultOrder() {
        let results = registry().search("   ")
        #expect(results.count == 5)
        // Disabled "Undo" must sort last despite 'Edit' preceding 'File'/'View'.
        #expect(results.last?.id == "undo")
        // Enabled File items come before the View item alphabetically by category.
        #expect(results.first?.category == "File")
    }

    @Test("keyword-only match surfaces an item whose title doesn't match")
    func keywordMatch() {
        let results = registry().search("usdz")
        #expect(results.first?.id == "export")
    }

    @Test("title match outranks a mere category/keyword match")
    func titleOutranksOthers() {
        // "sa" hits both Save titles strongly; ranking is deterministic.
        let results = registry().search("sa")
        #expect(results.first?.id == "save")   // shorter, tighter match sorts first
        #expect(results.contains { $0.id == "saveAs" })
    }

    @Test("no matches yields an empty result set")
    func noMatches() {
        #expect(registry().search("qqqq").isEmpty)
    }

    @Test("enabled items rank above disabled ones even on equal score")
    func enabledFirst() {
        let reg = ActionRegistry([
            ActionItem(id: "a", title: "Reset", category: "Edit", isEnabled: false),
            ActionItem(id: "b", title: "Reset", category: "Edit", isEnabled: true),
        ])
        let results = reg.search("reset")
        #expect(results.first?.id == "b")
        #expect(results.last?.id == "a")
    }

    @Test("ranking is a total order — stable across input permutations")
    func deterministicOrder() {
        let a = registry().search("s").map(\.id)
        let b = ActionRegistry(registry().items.reversed()).search("s").map(\.id)
        #expect(a == b)
    }
}
