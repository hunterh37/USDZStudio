import Foundation
import simd

/// One joint in a skeleton. Value-semantic with a stable `id` that survives edits so selection,
/// undo, and the weight table stay coherent when joints are inserted or renamed.
public struct RigJoint: Sendable, Equatable, Codable, Identifiable {
    /// Stable identity, independent of array position or authored name.
    public let id: String
    /// UsdSkel joint path token (e.g. `"Root/Hips/Spine"`), authoring name.
    public var path: String
    /// Index of the parent joint in the owning `Skeleton.joints`, or `nil` for a root.
    public var parent: Int?
    /// Local rest transform relative to the parent (the bind-time neutral pose).
    public var restLocal: RigTransform

    public init(id: String, path: String, parent: Int?, restLocal: RigTransform) {
        self.id = id
        self.path = path
        self.parent = parent
        self.restLocal = restLocal
    }

    /// The leaf name of the joint path (`"Spine"` for `"Root/Hips/Spine"`).
    public var name: String {
        String(path.split(separator: "/").last ?? Substring(path))
    }
}

/// A local translate/rotate/scale transform, the channel triple UsdSkel animation authors.
public struct RigTransform: Sendable, Equatable, Codable {
    public var translation: Vec3
    public var rotation: Quat
    public var scale: Vec3

    public init(translation: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = Vec3(1, 1, 1)) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = RigTransform()

    /// The column-major 4×4 for this transform.
    public var matrix: simd_double4x4 {
        Math.trs(translation: translation, rotation: rotation, scale: scale)
    }

    /// Decompose a 4×4 into translate/rotate/scale (scale from basis-column lengths).
    public init(decomposing m: simd_double4x4) {
        func axisLen(_ c: SIMD4<Double>) -> Double { simd_length(Vec3(c.x, c.y, c.z)) }
        self.init(translation: Math.origin(of: m),
                  rotation: Math.rotation(of: m),
                  scale: Vec3(axisLen(m.columns.0), axisLen(m.columns.1), axisLen(m.columns.2)))
    }
}

/// A joint hierarchy. Value type (CoW `struct`) so snapshots are cheap and undo is a stored copy.
///
/// Invariant (see `validate`): every joint's parent index refers to an earlier array element, so a
/// single forward pass evaluates forward kinematics. Stable joint IDs are unique.
public struct Skeleton: Sendable, Equatable, Codable {
    public private(set) var joints: [RigJoint]

    public init(joints: [RigJoint]) {
        self.joints = joints
    }

    /// Build from UsdSkel `joints` (relative token paths, topologically ordered) and
    /// `restTransforms` (row-major flattened, 16 doubles per joint). Parent links are derived from
    /// the path hierarchy. Returns `nil` if the arrays don't agree in length.
    public init?(jointPaths: [String], restTransformsFlat flat: [Double]) {
        guard flat.count == jointPaths.count * 16 else { return nil }
        var built: [RigJoint] = []
        for (i, path) in jointPaths.enumerated() {
            let m = Math.fromRowMajor(Array(flat[(i * 16)..<(i * 16 + 16)]))
            let parent = Skeleton.parentIndex(of: path, in: jointPaths)
            built.append(RigJoint(id: path, path: path, parent: parent,
                                  restLocal: RigTransform(decomposing: m)))
        }
        self.init(joints: built)
    }

    /// Index of the joint whose path is the parent prefix of `path` (nil for a root or unknown parent).
    static func parentIndex(of path: String, in paths: [String]) -> Int? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return paths.firstIndex(of: String(path[..<slash]))
    }

    public var jointCount: Int { joints.count }

    /// Index of the joint with the given stable ID.
    public func index(ofID id: String) -> Int? {
        joints.firstIndex { $0.id == id }
    }

    /// Index of the joint whose path matches exactly.
    public func index(ofPath path: String) -> Int? {
        joints.firstIndex { $0.path == path }
    }

    /// Direct-child indices of the joint at `index`.
    public func children(of index: Int) -> [Int] {
        joints.indices.filter { joints[$0].parent == index }
    }

    /// The chain of indices from the root down to `index`, inclusive, root first.
    public func ancestors(of index: Int) -> [Int] {
        var chain: [Int] = []
        var cursor: Int? = index
        while let c = cursor {
            chain.append(c)
            cursor = joints[c].parent
        }
        return chain.reversed()
    }

    /// Rest world transforms by forward kinematics: `world(j) = world(parent) · restLocal(j)`.
    /// Deterministic and order-independent given the topological invariant.
    public func restWorldMatrices() -> [simd_double4x4] {
        worldMatrices(locals: joints.map { $0.restLocal.matrix })
    }

    /// World transforms for arbitrary per-joint local matrices (must be parallel to `joints`).
    public func worldMatrices(locals: [simd_double4x4]) -> [simd_double4x4] {
        var world = [simd_double4x4](repeating: matrix_identity_double4x4, count: joints.count)
        for i in joints.indices {
            if let p = joints[i].parent {
                world[i] = world[p] * locals[i]
            } else {
                world[i] = locals[i]
            }
        }
        return world
    }

    /// Replace a joint's rest transform, preserving identity and topology (undo-friendly).
    public mutating func setRestLocal(_ transform: RigTransform, at index: Int) {
        joints[index].restLocal = transform
    }

    // MARK: UsdSkel mapping

    /// The `joints` token[] array (joint paths in authoring order).
    public var jointPaths: [String] { joints.map { $0.path } }

    /// The `restTransforms` matrix4d[] flattened row-major (16 doubles per joint).
    public var restTransformsFlat: [Double] {
        joints.flatMap { Math.rowMajor($0.restLocal.matrix) }
    }
}
