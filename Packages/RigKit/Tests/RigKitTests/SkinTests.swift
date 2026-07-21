import XCTest
@testable import RigKit

final class SkinTests: XCTestCase {
    func testNormalize() {
        let skin = SkinBinding(perVertex: [
            [Influence(joint: 0, weight: 3), Influence(joint: 1, weight: 1)],
            [Influence(joint: 0, weight: 0)],   // zero-sum vertex is left unchanged
        ]).normalized()
        XCTAssertEqual(skin.weightSum(0), 1, accuracy: 1e-12)
        XCTAssertEqual(skin.perVertex[0][0].weight, 0.75, accuracy: 1e-12)
        XCTAssertEqual(skin.weightSum(1), 0, accuracy: 1e-12)
    }

    func testPruneClampAndCounts() {
        let base = SkinBinding(perVertex: [[
            Influence(joint: 0, weight: 0.5),
            Influence(joint: 1, weight: 0.3),
            Influence(joint: 2, weight: 0.19),
            Influence(joint: 3, weight: 0.01),
        ]])
        let pruned = base.pruned(threshold: 0.05)
        XCTAssertEqual(pruned.perVertex[0].count, 3)
        let clamped = base.clamped(maxInfluences: 2)
        XCTAssertEqual(clamped.perVertex[0].map(\.joint), [0, 1])
        XCTAssertEqual(base.maxInfluenceCount, 4)
        XCTAssertEqual(SkinBinding(perVertex: []).maxInfluenceCount, 0)
        // maxInfluences 0 keeps nothing.
        XCTAssertEqual(base.clamped(maxInfluences: 0).perVertex[0].count, 0)
    }

    func testClampTieBreaksByJointIndex() {
        let clamped = SkinBinding(perVertex: [[
            Influence(joint: 5, weight: 0.5),
            Influence(joint: 2, weight: 0.5),
        ]]).clamped(maxInfluences: 1)
        XCTAssertEqual(clamped.perVertex[0][0].joint, 2)   // equal weight → lower joint index
    }

    func testRemappingJoints() {
        let remapped = SkinBinding(perVertex: [[
            Influence(joint: 1, weight: 1), Influence(joint: 9, weight: 1),
        ]]).remappingJoints([1: 2])
        XCTAssertEqual(remapped.perVertex[0].map(\.joint), [2, 9])   // 9 absent from map → kept
    }

    func testConformed() {
        let conformed = SkinBinding(perVertex: [[
            Influence(joint: 0, weight: 0.6),
            Influence(joint: 1, weight: 0.399),
            Influence(joint: 2, weight: 0.0001),
        ]]).conformed(maxInfluences: 1)
        XCTAssertEqual(conformed.perVertex[0].count, 1)
        XCTAssertEqual(conformed.weightSum(0), 1, accuracy: 1e-12)
    }

    func testFlattenRoundTrip() {
        let skin = SkinBinding(perVertex: [
            [Influence(joint: 0, weight: 0.7), Influence(joint: 1, weight: 0.3)],
            [Influence(joint: 2, weight: 1.0)],   // fewer than n → zero-padded
        ])
        let flat = skin.flattened(influencesPerVertex: 2)
        XCTAssertEqual(flat.indices, [0, 1, 2, 0])
        XCTAssertEqual(flat.weights, [0.7, 0.3, 1.0, 0.0])
        let back = SkinBinding.fromFlattened(indices: flat.indices, weights: flat.weights, influencesPerVertex: 2)
        XCTAssertEqual(back?.perVertex[0].map(\.joint), [0, 1])
    }

    func testFlattenTruncatesExtraInfluences() {
        let skin = SkinBinding(perVertex: [[
            Influence(joint: 0, weight: 0.5), Influence(joint: 1, weight: 0.3), Influence(joint: 2, weight: 0.2),
        ]])
        XCTAssertEqual(skin.flattened(influencesPerVertex: 2).indices, [0, 1])
    }

    func testFromFlattenedMalformed() {
        XCTAssertNil(SkinBinding.fromFlattened(indices: [0, 1], weights: [1], influencesPerVertex: 2))
        XCTAssertNil(SkinBinding.fromFlattened(indices: [0, 1, 2], weights: [1, 1, 1], influencesPerVertex: 2))
        XCTAssertNil(SkinBinding.fromFlattened(indices: [], weights: [], influencesPerVertex: 0))
    }

    func testCodable() throws {
        let skin = SkinBinding(perVertex: [[Influence(joint: 0, weight: 1)]])
        let data = try JSONEncoder().encode(skin)
        XCTAssertEqual(try JSONDecoder().decode(SkinBinding.self, from: data), skin)
    }
}
