import XCTest
@testable import RigKit

enum SkelCorpus {
    /// Build a humanoid skeleton from (leafName, parentLeaf) pairs with a shared naming style.
    static func humanoid(style: (String) -> String) -> Skeleton {
        // (canonicalLeaf, parentCanonicalLeaf?)
        let spec: [(String, String?)] = [
            ("Hips", nil), ("Spine", "Hips"), ("Spine1", "Spine"), ("Neck", "Spine1"), ("Head", "Neck"),
            ("LeftShoulder", "Spine1"), ("LeftArm", "LeftShoulder"), ("LeftForeArm", "LeftArm"), ("LeftHand", "LeftForeArm"),
            ("RightShoulder", "Spine1"), ("RightArm", "RightShoulder"), ("RightForeArm", "RightArm"), ("RightHand", "RightForeArm"),
            ("LeftUpLeg", "Hips"), ("LeftLeg", "LeftUpLeg"), ("LeftFoot", "LeftLeg"), ("LeftToeBase", "LeftFoot"),
            ("RightUpLeg", "Hips"), ("RightLeg", "RightUpLeg"), ("RightFoot", "RightLeg"), ("RightToeBase", "RightFoot"),
        ]
        var indexOf: [String: Int] = [:]
        for (i, s) in spec.enumerated() { indexOf[s.0] = i }
        func path(_ leaf: String) -> String {
            var parts = [style(leaf)]
            var cursor = spec[indexOf[leaf]!].1
            while let c = cursor { parts.append(style(c)); cursor = spec[indexOf[c]!].1 }
            return parts.reversed().joined(separator: "/")
        }
        let joints = spec.map { s in
            RigJoint(id: s.0, path: path(s.0), parent: s.1.flatMap { indexOf[$0] },
                     restLocal: RigTransform(translation: Vec3(0, 1, 0)))
        }
        return Skeleton(joints: joints)
    }

    static let mixamo = humanoid { "mixamorig:" + $0 }
    static let dotSide = humanoid { leaf in
        leaf.replacingOccurrences(of: "Left", with: "").replacingOccurrences(of: "Right", with: "")
            + (leaf.hasPrefix("Left") ? ".L" : leaf.hasPrefix("Right") ? ".R" : "")
    }
}

final class NormalizeTests: XCTestCase {
    func testNamespaceAndCamelCase() {
        XCTAssertEqual(HumanoidMap.normalize("mixamorig:Hips").core, "hips")
        let up = HumanoidMap.normalize("mixamorig:LeftUpLeg")
        XCTAssertEqual(up.core, "upleg")
        XCTAssertEqual(up.side, .left)
        let shoulder = HumanoidMap.normalize("RightShoulder")
        XCTAssertEqual(shoulder.core, "shoulder")
        XCTAssertEqual(shoulder.side, .right)
    }

    func testSeparatorsAndDigits() {
        XCTAssertEqual(HumanoidMap.normalize("thigh.L").side, .left)
        XCTAssertEqual(HumanoidMap.normalize("thigh.L").core, "thigh")
        XCTAssertEqual(HumanoidMap.normalize("hand_r").side, .right)
        let bip = HumanoidMap.normalize("Bip01_L_Thigh")
        XCTAssertEqual(bip.side, .left)
        XCTAssertTrue(bip.core.contains("thigh"))
        XCTAssertEqual(HumanoidMap.normalize("Spine1").core, "spine1")
    }
}

final class ScoreTests: XCTestCase {
    func testScoreBranches() {
        let hips = HumanoidMap.canonicalBones.first { $0.name == "Hips" }!
        XCTAssertEqual(HumanoidMap.score(core: "hips", side: .center, against: hips), 1.0)      // exact
        XCTAssertEqual(HumanoidMap.score(core: "myhips", side: .center, against: hips), 0.7)    // substring
        XCTAssertEqual(HumanoidMap.score(core: "hips", side: .left, against: hips), 0)          // side mismatch
        XCTAssertEqual(HumanoidMap.score(core: "xyz", side: .center, against: hips), 0)         // no match
    }
}

final class IdentifyTests: XCTestCase {
    func testMixamoMapping() {
        let mapping = HumanoidMap.identify(SkelCorpus.mixamo)
        XCTAssertEqual(mapping.matches["Hips"]?.jointPath, "mixamorig:Hips")
        XCTAssertEqual(mapping.matches["Chest"]?.jointIndex, SkelCorpus.mixamo.index(ofID: "Spine1"))
        XCTAssertEqual(mapping.matches["LeftUpperLeg"]?.jointIndex, SkelCorpus.mixamo.index(ofID: "LeftUpLeg"))
        XCTAssertEqual(mapping.matches["RightHand"]?.jointIndex, SkelCorpus.mixamo.index(ofID: "RightHand"))
        // Every canonical bone matched → nothing low-confidence.
        XCTAssertTrue(mapping.lowConfidence.isEmpty, "unexpected low-confidence: \(mapping.lowConfidence)")
        XCTAssertNotNil(mapping.jointIndex(for: "Head"))
    }

    func testDotSideMapping() {
        let mapping = HumanoidMap.identify(SkelCorpus.dotSide)
        XCTAssertNotNil(mapping.jointIndex(for: "LeftHand"))
        XCTAssertNotNil(mapping.jointIndex(for: "RightFoot"))
    }

    func testUnmatchedAndAlternates() {
        let generic = SkeletonFit.fitGeneric(RigMesh(points: [Vec3(0, 0, 0), Vec3(0, 2, 0)]), jointCount: 3)
        let mapping = HumanoidMap.identify(generic)
        XCTAssertEqual(mapping.matches["Hips"], .unmatched)
        XCTAssertEqual(mapping.lowConfidence.count, HumanoidMap.canonicalBones.count)
        XCTAssertNil(mapping.jointIndex(for: "Hips"))
    }

    func testAlternatesRecorded() {
        // Two joints both containing "hand" → one wins, the other becomes an alternate.
        let skel = Skeleton(joints: [
            RigJoint(id: "h", path: "Hand", parent: nil, restLocal: .identity),
            RigJoint(id: "h2", path: "Hand/MyHandThing", parent: 0, restLocal: .identity),
        ])
        // Both are center-sided "hand" cores, but Hand canonical is left/right → neither matches;
        // instead use a case that does match to record alternates: rename to right side.
        let rightHands = Skeleton(joints: [
            RigJoint(id: "a", path: "RightHand", parent: nil, restLocal: .identity),
            RigJoint(id: "b", path: "RightHand/RightHandExtra", parent: 0, restLocal: .identity),
        ])
        let mapping = HumanoidMap.identify(rightHands)
        let match = mapping.matches["RightHand"]
        XCTAssertNotNil(match?.jointIndex)
        XCTAssertFalse(match!.alternates.isEmpty)
        _ = skel
    }

    func testMappingCodable() throws {
        let mapping = HumanoidMap.identify(SkelCorpus.mixamo)
        let data = try JSONEncoder().encode(mapping)
        let back = try JSONDecoder().decode(HumanoidMapping.self, from: data)
        XCTAssertEqual(back.matches["Hips"]?.jointPath, "mixamorig:Hips")
    }
}
