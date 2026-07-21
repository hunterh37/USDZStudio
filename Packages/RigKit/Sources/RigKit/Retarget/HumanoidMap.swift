import Foundation

/// Which side of the body a canonical bone belongs to.
public enum BoneSide: String, Sendable, Equatable, Codable {
    case center, left, right
}

/// One entry in the canonical humanoid standard (Mixamo / Unity-Humanoid style).
public struct CanonicalBone: Sendable, Equatable {
    public let name: String
    public let side: BoneSide
    /// Name tokens the matcher looks for (already normalized: lowercase, no separators).
    public let keywords: [String]
}

/// The result of matching one canonical bone to an authored skeleton.
public struct BoneMatch: Sendable, Equatable, Codable {
    public var jointIndex: Int?
    public var jointPath: String?
    /// Confidence in `0...1`. `0` means unmatched.
    public var confidence: Double
    /// Other authored joint paths that scored above zero, best first.
    public var alternates: [String]

    public init(jointIndex: Int?, jointPath: String?, confidence: Double, alternates: [String]) {
        self.jointIndex = jointIndex
        self.jointPath = jointPath
        self.confidence = confidence
        self.alternates = alternates
    }

    public static let unmatched = BoneMatch(jointIndex: nil, jointPath: nil, confidence: 0, alternates: [])
}

/// A full canonical→authored mapping for a skeleton.
public struct HumanoidMapping: Sendable, Equatable, Codable {
    /// Canonical bone name → best match.
    public var matches: [String: BoneMatch]
    /// Canonical bone names with confidence below the caller's threshold or no candidate.
    public var lowConfidence: [String]

    public init(matches: [String: BoneMatch], lowConfidence: [String]) {
        self.matches = matches
        self.lowConfidence = lowConfidence
    }

    /// The authored joint index bound to a canonical bone, if matched.
    public func jointIndex(for canonical: String) -> Int? {
        matches[canonical]?.jointIndex
    }
}

/// The canonical humanoid rig standard + deterministic fuzzy matching against arbitrary skeletons.
public enum HumanoidMap {
    /// The canonical bone set. Order is stable; every `.left` has a mirror `.right` with the same
    /// keyword core (a machine-checkable symmetry invariant).
    public static let canonicalBones: [CanonicalBone] = {
        var bones: [CanonicalBone] = [
            CanonicalBone(name: "Hips", side: .center, keywords: ["hips", "hip", "pelvis"]),
            CanonicalBone(name: "Spine", side: .center, keywords: ["spine"]),
            CanonicalBone(name: "Chest", side: .center, keywords: ["chest", "spine1", "spine2"]),
            CanonicalBone(name: "Neck", side: .center, keywords: ["neck"]),
            CanonicalBone(name: "Head", side: .center, keywords: ["head"]),
        ]
        // Symmetric limb bones, generated so left/right stay in lockstep.
        let limbs: [(String, [String])] = [
            ("Shoulder", ["shoulder", "clavicle", "collar"]),
            ("UpperArm", ["upperarm", "uparm", "arm"]),
            ("LowerArm", ["lowerarm", "forearm", "loarm"]),
            ("Hand", ["hand", "wrist"]),
            ("UpperLeg", ["upperleg", "upleg", "thigh"]),
            ("LowerLeg", ["lowerleg", "leg", "calf", "shin"]),
            ("Foot", ["foot", "ankle"]),
            ("Toes", ["toes", "toe", "ball"]),
        ]
        for (core, kw) in limbs {
            bones.append(CanonicalBone(name: "Left\(core)", side: .left, keywords: kw))
            bones.append(CanonicalBone(name: "Right\(core)", side: .right, keywords: kw))
        }
        return bones
    }()

    /// Normalize an authored joint name: strip a `mixamorig:`-style namespace, split on separators,
    /// detect the side marker, and return the lowercased core (no side token) + the detected side.
    public static func normalize(_ rawName: String) -> (core: String, side: BoneSide) {
        var name = rawName
        if let colon = name.lastIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        // Tokenize on separators AND camelCase / letter↔digit boundaries so `LeftShoulder`,
        // `LeftUpLeg`, `thigh.L`, and `Bip01_L_Thigh` all split into side + core tokens.
        var tokens: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { tokens.append(current.lowercased()); current = "" } }
        for ch in name {
            if !ch.isLetter && !ch.isNumber { flush(); continue }
            if let prev = current.last {
                let boundary = (prev.isLowercase && ch.isUppercase)
                    || (prev.isLetter && ch.isNumber)
                    || (prev.isNumber && ch.isLetter)
                if boundary { flush() }
            }
            current.append(ch)
        }
        flush()

        var side: BoneSide = .center
        if tokens.contains("left") || tokens.contains("l") { side = .left }
        if tokens.contains("right") || tokens.contains("r") { side = .right }
        tokens.removeAll { $0 == "left" || $0 == "right" || $0 == "l" || $0 == "r" }
        return (tokens.joined(), side)
    }

    /// Score how well an authored (core, side) matches a canonical bone. `0` = no match.
    static func score(core: String, side: BoneSide, against bone: CanonicalBone) -> Double {
        // Side must agree (a center bone accepts only center-detected names).
        guard side == bone.side else { return 0 }
        var best = 0.0
        for kw in bone.keywords {
            if core == kw { best = max(best, 1.0) }
            else if core.contains(kw) { best = max(best, 0.7) }
        }
        return best
    }

    /// Identify canonical bones in `skeleton`. Deterministic and explainable: greedy assignment by
    /// descending score so no authored joint is claimed by two canonical bones.
    /// `threshold` decides which matches are flagged low-confidence.
    public static func identify(_ skeleton: Skeleton, threshold: Double = 0.6) -> HumanoidMapping {
        let normalized = skeleton.joints.map { normalize($0.name) }

        // Build all (canonical, joint, score) candidates above zero.
        struct Candidate { let bone: Int; let joint: Int; let score: Double }
        var candidates: [Candidate] = []
        for (b, bone) in canonicalBones.enumerated() {
            for (j, n) in normalized.enumerated() {
                let s = score(core: n.core, side: n.side, against: bone)
                if s > 0 { candidates.append(Candidate(bone: b, joint: j, score: s)) }
            }
        }
        // Greedy: highest score first; ties break by bone order then joint order for determinism.
        candidates.sort {
            $0.score != $1.score ? $0.score > $1.score
                : ($0.bone != $1.bone ? $0.bone < $1.bone : $0.joint < $1.joint)
        }

        var claimedJoint = Set<Int>()
        var claimedBone = Set<Int>()
        var alternatesByBone: [Int: [String]] = [:]
        var chosenJoint: [Int: Int] = [:]
        var chosenConfidence: [Int: Double] = [:]

        for cand in candidates {
            // Every above-zero candidate is an alternate for its bone (best-scoring first).
            alternatesByBone[cand.bone, default: []].append(skeleton.joints[cand.joint].path)
            guard !claimedBone.contains(cand.bone), !claimedJoint.contains(cand.joint) else { continue }
            claimedBone.insert(cand.bone)
            claimedJoint.insert(cand.joint)
            chosenJoint[cand.bone] = cand.joint
            chosenConfidence[cand.bone] = cand.score
        }

        var matches: [String: BoneMatch] = [:]
        var lowConfidence: [String] = []
        for (b, bone) in canonicalBones.enumerated() {
            if let j = chosenJoint[b] {
                let chosenPath = skeleton.joints[j].path
                let alternates = (alternatesByBone[b] ?? []).filter { $0 != chosenPath }
                matches[bone.name] = BoneMatch(jointIndex: j, jointPath: chosenPath,
                                               confidence: chosenConfidence[b]!, alternates: alternates)
            } else {
                matches[bone.name] = .unmatched
            }
            if (matches[bone.name]?.confidence ?? 0) < threshold { lowConfidence.append(bone.name) }
        }
        return HumanoidMapping(matches: matches, lowConfidence: lowConfidence)
    }
}
