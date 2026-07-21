import Foundation

/// Committed fuzz corpus (specs/mesh-editing.md §Testing: "fuzz corpus in CI").
///
/// Two parts:
/// 1. **Regression seeds** — every seed that ever exposed a bug is pinned here
///    forever, with a note. Add the failing seed *before* fixing the bug.
/// 2. **Rolling sweep** — a deterministic seed range. Local runs default to 40
///    iterations; CI deepens the sweep via `MESHKIT_FUZZ_ITERATIONS` without
///    any code change.
enum FuzzCorpus {

    /// Seeds pinned from past failures / hand-audited interesting cases.
    /// Never remove entries; the corpus only grows.
    static let regressionSeeds: [UInt64] = [
        0xC0FFEE,          // original sweep origin (Phase 6 bring-up)
        0xC0FFEE + 7,      // bevel after extrude on jittered cube (BevelEdges bring-up)
        0xC0FFEE + 23,     // merge-by-distance collapsing a full grid row
        0xC0FFEE + 31,     // delete → bevel on the surviving region
        0xC0FFEE + 42,      // loop cut on a jittered grid strip (LoopCut bring-up)
    ]

    /// `MESHKIT_FUZZ_ITERATIONS` (CI knob) > default 40.
    static var sweepIterations: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["MESHKIT_FUZZ_ITERATIONS"],
           let n = UInt64(raw), n > 0 {
            return n
        }
        return 40
    }

    /// Full corpus for the parameterized fuzz test.
    static var allSeeds: [UInt64] {
        regressionSeeds + (0..<sweepIterations).map { 0xC0FFEE &+ $0 }
    }
}
