import Foundation
import simd

/// A minimal mesh sample: the vertex positions auto-rig reasons about (no topology needed for the
/// landmark fit or the bone-glow weight solve).
public struct RigMesh: Sendable, Equatable {
    public var points: [Vec3]
    public init(points: [Vec3]) { self.points = points }

    /// Axis-aligned bounds `(min, max)`; a zero box for an empty mesh.
    public var bounds: (min: Vec3, max: Vec3) {
        guard let first = points.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

public enum AutoRigKind: String, Sendable, Equatable, CaseIterable, Codable {
    case humanoid, generic
}

/// Landmark / geometry skeleton placement. Deterministic given the mesh (and `seed`, reserved for
/// stable tie-breaking). Symmetry-aware: left/right joints are exact mirror images about the mesh's
/// vertical mid-plane, and everything is scaled to the mesh bounds.
public enum SkeletonFit {
    /// Fractions of body height (0 = feet, 1 = crown) for the humanoid landmark joints.
    enum P {
        static let hips = 0.53, spine = 0.60, chest = 0.70, neck = 0.83, head = 0.90
        static let shoulder = 0.80, elbow = 0.80, wrist = 0.80
        static let knee = 0.28, ankle = 0.04, toe = 0.02
    }

    public static func fit(_ mesh: RigMesh, kind: AutoRigKind, seed: Int = 0) -> Skeleton {
        switch kind {
        case .humanoid: return fitHumanoid(mesh, seed: seed)
        case .generic: return fitGeneric(mesh, jointCount: 5, seed: seed)
        }
    }

    /// A canonical-named humanoid skeleton fit to the mesh bounds (T-pose assumption: arms along X).
    public static func fitHumanoid(_ mesh: RigMesh, seed: Int = 0) -> Skeleton {
        let (lo, hi) = mesh.bounds
        let h = hi.y - lo.y
        let w = hi.x - lo.x
        let cx = (lo.x + hi.x) / 2
        let cz = (lo.z + hi.z) / 2
        func y(_ f: Double) -> Double { lo.y + h * f }
        func center(_ f: Double) -> Vec3 { Vec3(cx, y(f), cz) }

        let armStep = w * 0.20          // spacing of arm joints outward along X
        let legOffset = w * 0.12        // hip/leg lateral offset
        let footZ = cz + h * 0.06       // toes forward in +Z

        // World-space landmark positions per canonical bone.
        var world: [(String, String?, Vec3)] = [
            ("Hips", nil, center(P.hips)),
            ("Spine", "Hips", center(P.spine)),
            ("Chest", "Spine", center(P.chest)),
            ("Neck", "Chest", center(P.neck)),
            ("Head", "Neck", center(P.head)),
        ]
        func arm(_ side: BoneSide) {
            let s: Double = side == .left ? -1 : 1
            let px = side == .left ? "Left" : "Right"
            world.append(("\(px)Shoulder", "Chest", Vec3(cx + s * armStep * 0.6, y(P.shoulder), cz)))
            world.append(("\(px)UpperArm", "\(px)Shoulder", Vec3(cx + s * armStep * 1.2, y(P.shoulder), cz)))
            world.append(("\(px)LowerArm", "\(px)UpperArm", Vec3(cx + s * armStep * 2.0, y(P.elbow), cz)))
            world.append(("\(px)Hand", "\(px)LowerArm", Vec3(cx + s * armStep * 2.8, y(P.wrist), cz)))
        }
        func leg(_ side: BoneSide) {
            let s: Double = side == .left ? -1 : 1
            let px = side == .left ? "Left" : "Right"
            world.append(("\(px)UpperLeg", "Hips", Vec3(cx + s * legOffset, y(P.hips), cz)))
            world.append(("\(px)LowerLeg", "\(px)UpperLeg", Vec3(cx + s * legOffset, y(P.knee), cz)))
            world.append(("\(px)Foot", "\(px)LowerLeg", Vec3(cx + s * legOffset, y(P.ankle), cz)))
            world.append(("\(px)Toes", "\(px)Foot", Vec3(cx + s * legOffset, y(P.toe), footZ)))
        }
        arm(.left); arm(.right); leg(.left); leg(.right)

        return assemble(world)
    }

    /// A generic spine chain of `jointCount` joints along the mesh's tallest axis.
    public static func fitGeneric(_ mesh: RigMesh, jointCount: Int, seed: Int = 0) -> Skeleton {
        let (lo, hi) = mesh.bounds
        let n = max(2, jointCount)
        let cx = (lo.x + hi.x) / 2, cz = (lo.z + hi.z) / 2
        var world: [(String, String?, Vec3)] = []
        for i in 0..<n {
            let f = Double(i) / Double(n - 1)
            let pos = Vec3(cx, lo.y + (hi.y - lo.y) * f, cz)
            world.append(("Joint\(i)", i == 0 ? nil : "Joint\(i - 1)", pos))
        }
        return assemble(world)
    }

    /// Turn world-space landmark positions into a `Skeleton` whose local rest transforms reproduce
    /// those positions under FK (translation-only locals: `local.t = worldPos - parentWorldPos`).
    static func assemble(_ world: [(name: String, parent: String?, pos: Vec3)]) -> Skeleton {
        var indexOf: [String: Int] = [:]
        for (i, entry) in world.enumerated() { indexOf[entry.name] = i }
        var joints: [RigJoint] = []
        for entry in world {
            let parentIndex = entry.parent.flatMap { indexOf[$0] }
            let parentPos = parentIndex.map { world[$0].pos } ?? .zero
            let localT = entry.pos - parentPos
            joints.append(RigJoint(id: entry.name, path: pathFor(entry.name, world: world, indexOf: indexOf),
                                   parent: parentIndex,
                                   restLocal: RigTransform(translation: localT)))
        }
        return Skeleton(joints: joints)
    }

    /// Build a `/`-joined joint path from the parent chain.
    static func pathFor(_ name: String, world: [(name: String, parent: String?, pos: Vec3)],
                        indexOf: [String: Int]) -> String {
        var parts = [name]
        var cursor = world[indexOf[name]!].parent
        while let c = cursor {
            parts.append(c)
            cursor = world[indexOf[c]!].parent
        }
        return parts.reversed().joined(separator: "/")
    }
}
