import Foundation
import simd

/// Where a constraint reads its goal from: another joint, or a fixed world value.
public enum ConstraintSource: Sendable, Equatable {
    case joint(Int)
    case worldPosition(Vec3)
    case worldTransform(position: Vec3, rotation: Quat, scale: Vec3)
}

/// The kind of coupling a constraint imposes on its constrained joint.
public enum ConstraintKind: String, Sendable, Equatable, CaseIterable, Codable {
    case point   // match world position
    case orient  // match world orientation
    case parent  // match both position and orientation
    case aim     // rotate so a local axis points at the source
    case scale   // match local scale
}

/// A single weighted constraint. Constraints are evaluated in list order, each re-reading the world
/// state produced by the previous one, so ordering is explicit and deterministic.
public struct Constraint: Sendable, Equatable {
    public var constrained: Int
    public var source: ConstraintSource
    public var kind: ConstraintKind
    /// Blend factor in `0...1`; clamped on evaluation.
    public var weight: Double
    /// Local aim axis for `.aim` (defaults to +X).
    public var aimAxis: Vec3

    public init(constrained: Int, source: ConstraintSource, kind: ConstraintKind,
                weight: Double = 1.0, aimAxis: Vec3 = Vec3(1, 0, 0)) {
        self.constrained = constrained
        self.source = source
        self.kind = kind
        self.weight = weight
        self.aimAxis = aimAxis
    }
}

public enum Constraints {
    /// Evaluate constraints in order over a pose, returning the constrained pose.
    public static func apply(_ constraints: [Constraint], to startPose: Pose,
                             skeleton: Skeleton) -> Pose {
        var pose = startPose
        for constraint in constraints {
            pose = applyOne(constraint, to: pose, skeleton: skeleton)
        }
        return pose
    }

    static func applyOne(_ c: Constraint, to pose: Pose, skeleton: Skeleton) -> Pose {
        let w = simd_clamp(c.weight, 0.0, 1.0)
        guard w > 0 else { return pose }

        let worlds = pose.worldMatrices(skeleton)
        let j = c.constrained
        let parentWorld: simd_double4x4
        if let p = skeleton.joints[j].parent { parentWorld = worlds[p] } else { parentWorld = matrix_identity_double4x4 }
        let parentRot = Math.rotation(of: parentWorld)
        let parentInv = parentWorld.inverse

        let (srcPos, srcRot, srcScale) = resolve(c.source, worlds: worlds, pose: pose)

        var local = pose.locals[j]
        let curWorldPos = Math.origin(of: worlds[j])
        let curWorldRot = Math.rotation(of: worlds[j])

        switch c.kind {
        case .point:
            let newWorldPos = mix(curWorldPos, srcPos, w)
            local.translation = transformPoint(parentInv, newWorldPos)
        case .orient:
            let newWorldRot = curWorldRot.slerp(to: srcRot, t: w)
            local.rotation = (parentRot.conjugate.multiplied(by: newWorldRot)).normalized
        case .parent:
            let newWorldPos = mix(curWorldPos, srcPos, w)
            let newWorldRot = curWorldRot.slerp(to: srcRot, t: w)
            local.translation = transformPoint(parentInv, newWorldPos)
            local.rotation = (parentRot.conjugate.multiplied(by: newWorldRot)).normalized
        case .aim:
            let curDir = curWorldRot.act(c.aimAxis)
            let desiredDir = srcPos - curWorldPos
            let delta = Math.rotationBetween(curDir, desiredDir)
            let aimed = delta.multiplied(by: curWorldRot)
            let newWorldRot = curWorldRot.slerp(to: aimed, t: w)
            local.rotation = (parentRot.conjugate.multiplied(by: newWorldRot)).normalized
        case .scale:
            local.scale = mix(local.scale, srcScale, w)
        }
        return pose.setting(local, at: j)
    }

    static func resolve(_ source: ConstraintSource, worlds: [simd_double4x4], pose: Pose) -> (Vec3, Quat, Vec3) {
        switch source {
        case .joint(let s):
            return (Math.origin(of: worlds[s]), Math.rotation(of: worlds[s]), pose.locals[s].scale)
        case .worldPosition(let p):
            return (p, .identity, Vec3(1, 1, 1))
        case .worldTransform(let p, let r, let sc):
            return (p, r, sc)
        }
    }

    static func transformPoint(_ m: simd_double4x4, _ p: Vec3) -> Vec3 {
        let v = m * SIMD4<Double>(p, 1)
        return Vec3(v.x, v.y, v.z)
    }

    static func mix(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 { a + (b - a) * t }
}
