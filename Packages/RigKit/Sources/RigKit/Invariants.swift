import Foundation
import simd

/// A validation finding for a rig construct (mirrors `MechanismKit.JointIssue`).
public struct RigIssue: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable { case error, warning }
    public var severity: Severity
    public var message: String
    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Shared, machine-checkable invariants used by solvers, the auto-rig, and the test harness.
public enum RigInvariants {
    // MARK: Skeleton

    /// Validate a skeleton's structure: unique IDs, non-empty paths, in-range parents, and the
    /// topological ordering (every parent precedes its child) that makes single-pass FK valid.
    public static func validate(_ skeleton: Skeleton) -> [RigIssue] {
        var issues: [RigIssue] = []
        var seenIDs = Set<String>()
        for (i, joint) in skeleton.joints.enumerated() {
            if joint.path.isEmpty { issues.append(.init(.error, "joint \(i) has an empty path")) }
            if !seenIDs.insert(joint.id).inserted {
                issues.append(.init(.error, "duplicate joint id '\(joint.id)'"))
            }
            if let p = joint.parent {
                if p < 0 || p >= skeleton.joints.count {
                    issues.append(.init(.error, "joint \(i) parent \(p) out of range"))
                } else if p >= i {
                    issues.append(.init(.error, "joint \(i) parent \(p) is not topologically before it"))
                }
            }
        }
        return issues
    }

    public static func isValid(_ skeleton: Skeleton) -> Bool {
        !validate(skeleton).contains { $0.severity == .error }
    }

    // MARK: Skin

    /// Worst absolute deviation of any vertex's weight-sum from 1 (over vertices with any weight).
    public static func weightSumResidual(_ skin: SkinBinding) -> Double {
        var worst = 0.0
        for v in 0..<skin.vertexCount {
            let sum = skin.weightSum(v)
            if sum > 1e-12 { worst = max(worst, abs(sum - 1.0)) }
        }
        return worst
    }

    /// Whether every vertex is within the influence cap.
    public static func respectsInfluenceCap(_ skin: SkinBinding, cap: Int) -> Bool {
        skin.maxInfluenceCount <= cap
    }

    // MARK: Humanoid map

    /// Validate a canonical standard: names unique, left/right symmetric (equal keyword cores).
    /// Defaults to the shipped standard; accepts an override so the failure branches are testable.
    public static func validateCanonicalStandard(
        _ bones: [CanonicalBone] = HumanoidMap.canonicalBones) -> [RigIssue] {
        var issues: [RigIssue] = []
        var names = Set<String>()
        for bone in bones {
            if !names.insert(bone.name).inserted {
                issues.append(.init(.error, "duplicate canonical bone '\(bone.name)'"))
            }
        }
        for bone in bones where bone.side == .left {
            let mirror = "Right" + bone.name.dropFirst("Left".count)
            guard let r = bones.first(where: { $0.name == mirror }) else {
                issues.append(.init(.error, "left bone '\(bone.name)' has no right mirror"))
                continue
            }
            if r.keywords != bone.keywords {
                issues.append(.init(.error, "asymmetric keywords for '\(bone.name)'/'\(mirror)'"))
            }
        }
        return issues
    }

    /// No authored joint is claimed by two canonical bones, and each mapped parent canonical bone's
    /// joint is an ancestor of its child canonical bone's joint. Returns issues (empty == valid).
    public static func validateMapping(_ mapping: HumanoidMapping, skeleton: Skeleton) -> [RigIssue] {
        var issues: [RigIssue] = []
        var claimed: [Int: String] = [:]
        for (name, match) in mapping.matches {
            guard let j = match.jointIndex else { continue }
            if let other = claimed[j] {
                issues.append(.init(.error, "joint \(j) claimed by both '\(name)' and '\(other)'"))
            }
            claimed[j] = name
        }
        // Parent/child ancestry for the spine chain (Hips→Spine→Chest→Neck→Head).
        let chain = ["Hips", "Spine", "Chest", "Neck", "Head"]
        for i in 1..<chain.count {
            guard let childJ = mapping.jointIndex(for: chain[i]),
                  let parentJ = mapping.jointIndex(for: chain[i - 1]) else { continue }
            if !skeleton.ancestors(of: childJ).contains(parentJ) {
                issues.append(.init(.warning, "'\(chain[i-1])' is not an ancestor of '\(chain[i])'"))
            }
        }
        return issues
    }
}
