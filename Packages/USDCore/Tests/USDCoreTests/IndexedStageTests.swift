import Foundation
import Testing
@testable import USDCore

/// `IndexedStage` must be observationally identical to the unindexed defaults —
/// it is a pure performance substitution, so every test here asserts parity with
/// the plain `StageSnapshot` path rather than asserting hand-written expectations.
@Suite("IndexedStage")
struct IndexedStageTests {
    /// Builds a hierarchy `breadth` wide and `depth` deep under a single root.
    static func makeStage(depth: Int, breadth: Int) -> StageSnapshot {
        func build(prefix: String, level: Int) -> [Prim] {
            guard level < depth else { return [] }
            return (0..<breadth).map { i in
                let path = "\(prefix)/n\(level)_\(i)"
                return Prim(
                    path: PrimPath(path)!,
                    typeName: level == depth - 1 ? "Mesh" : "Xform",
                    children: build(prefix: path, level: level + 1))
            }
        }
        return StageSnapshot(
            metadata: StageMetadata(defaultPrim: "root"),
            rootPrims: [Prim(path: PrimPath("/root")!, typeName: "Xform",
                             children: build(prefix: "/root", level: 0))])
    }

    @Test("traversal order matches the unindexed default exactly")
    func traversalParity() {
        let stage = Self.makeStage(depth: 4, breadth: 3)
        #expect(IndexedStage(stage).allPrims() == stage.allPrims())
    }

    @Test("every path resolves to the same prim as the unindexed lookup")
    func lookupParity() {
        let stage = Self.makeStage(depth: 3, breadth: 3)
        let indexed = IndexedStage(stage)
        for prim in stage.allPrims() {
            #expect(indexed.prim(at: prim.path) == stage.prim(at: prim.path))
        }
    }

    @Test("an absent path returns nil, matching the unindexed lookup")
    func missingPath() {
        let stage = Self.makeStage(depth: 2, breadth: 2)
        let absent = PrimPath("/root/nope")!
        #expect(IndexedStage(stage).prim(at: absent) == nil)
        #expect(stage.prim(at: absent) == nil)
    }

    @Test("metadata, source URL, and roots pass through untouched")
    func passthrough() {
        let url = URL(fileURLWithPath: "/tmp/a.usda")
        let stage = StageSnapshot(
            sourceURL: url,
            metadata: StageMetadata(upAxis: .z, metersPerUnit: 0.01, defaultPrim: "root"),
            rootPrims: [Prim(path: PrimPath("/root")!, typeName: "Xform")])
        let indexed = IndexedStage(stage)
        #expect(indexed.sourceURL == url)
        #expect(indexed.metadata == stage.metadata)
        #expect(indexed.rootPrims == stage.rootPrims)
        #expect(indexed.primCount == stage.primCount)
    }

    @Test("derived helpers built on allPrims still work through the index")
    func derivedHelpers() {
        let stage = Self.makeStage(depth: 2, breadth: 2)
        let indexed = IndexedStage(stage)
        #expect(indexed.prims(named: "n0_0") == stage.prims(named: "n0_0"))
    }

    @Test("an empty stage indexes cleanly")
    func emptyStage() {
        let indexed = IndexedStage(StageSnapshot())
        #expect(indexed.allPrims().isEmpty)
        #expect(indexed.primCount == 0)
        #expect(indexed.prim(at: PrimPath("/root")!) == nil)
    }

    @Test("a duplicated path keeps the first occurrence, as the tree walk would")
    func duplicatePathKeepsFirst() {
        // Malformed but reachable via the bridge; must not trap or disagree.
        let dup = PrimPath("/root/dup")!
        let stage = StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/root")!, typeName: "Xform", children: [
                Prim(path: dup, typeName: "Mesh"),
                Prim(path: dup, typeName: "Xform"),
            ]),
        ])
        #expect(IndexedStage(stage).prim(at: dup) == stage.prim(at: dup))
        #expect(IndexedStage(stage).prim(at: dup)?.typeName == "Mesh")
    }

    @Test("indexed() wraps a plain stage and is idempotent on an indexed one")
    func indexedHelper() {
        let stage = Self.makeStage(depth: 2, breadth: 2)
        let once = stage.indexed()
        #expect(once is IndexedStage)
        #expect(once.allPrims() == stage.allPrims())

        let twice = once.indexed()
        #expect(twice is IndexedStage)
        #expect(twice.allPrims() == once.allPrims())
    }

    /// Guards the actual point of the type: repeated lookups must not re-walk.
    /// Deliberately a generous ratio so the gate catches an algorithmic
    /// regression (index silently bypassed) without flaking on a loaded runner.
    @Test("repeated lookups are dramatically cheaper than the unindexed walk")
    func lookupIsNotLinear() {
        let stage = Self.makeStage(depth: 5, breadth: 6)
        let targets = stage.allPrims().map(\.path)
        #expect(targets.count > 5_000)

        let indexed = IndexedStage(stage)
        let indexedStart = Date()
        for path in targets { _ = indexed.prim(at: path) }
        let indexedElapsed = Date().timeIntervalSince(indexedStart)

        // Sample the unindexed path — running all of them is far too slow.
        let sample = Array(targets.prefix(200))
        let plainStart = Date()
        for path in sample { _ = stage.prim(at: path) }
        let plainElapsed = Date().timeIntervalSince(plainStart)

        let indexedPerLookup = indexedElapsed / Double(targets.count)
        let plainPerLookup = plainElapsed / Double(sample.count)
        #expect(indexedPerLookup < plainPerLookup)
    }
}
