import Foundation
import simd

/// A pose: one local transform per joint, parallel to `Skeleton.joints`.
///
/// Pure value type. FK evaluation is a pure function of the pose and its skeleton, so a solved pose
/// is fully reproducible and diffable.
public struct Pose: Sendable, Equatable, Codable {
    public private(set) var locals: [RigTransform]

    public init(locals: [RigTransform]) {
        self.locals = locals
    }

    /// The skeleton's rest pose as an editable `Pose`.
    public init(rest skeleton: Skeleton) {
        self.locals = skeleton.joints.map { $0.restLocal }
    }

    public var jointCount: Int { locals.count }

    /// The local transform at a joint index.
    public func local(_ index: Int) -> RigTransform { locals[index] }

    /// Author one joint's local transform (returns a copy; value semantics keep undo trivial).
    public func setting(_ transform: RigTransform, at index: Int) -> Pose {
        var copy = locals
        copy[index] = transform
        return Pose(locals: copy)
    }

    /// World matrices for this pose under `skeleton`.
    public func worldMatrices(_ skeleton: Skeleton) -> [simd_double4x4] {
        skeleton.worldMatrices(locals: locals.map { $0.matrix })
    }

    /// World-space origin of each joint (the point the IK solvers and metrics reason about).
    public func worldPositions(_ skeleton: Skeleton) -> [Vec3] {
        worldMatrices(skeleton).map { Math.origin(of: $0) }
    }

    /// World-space origin of a single joint.
    public func worldPosition(_ index: Int, in skeleton: Skeleton) -> Vec3 {
        Math.origin(of: worldMatrices(skeleton)[index])
    }

    // MARK: UsdSkel animation channels

    /// Translations `float3[]` flattened (3 doubles per joint).
    public var translationsFlat: [Double] {
        locals.flatMap { [$0.translation.x, $0.translation.y, $0.translation.z] }
    }

    /// Rotations `quatf[]` flattened `(w, x, y, z)` per joint — the USD element order.
    public var rotationsFlat: [Double] {
        locals.flatMap { [$0.rotation.w, $0.rotation.x, $0.rotation.y, $0.rotation.z] }
    }

    /// Scales `float3[]` flattened (3 doubles per joint).
    public var scalesFlat: [Double] {
        locals.flatMap { [$0.scale.x, $0.scale.y, $0.scale.z] }
    }
}
