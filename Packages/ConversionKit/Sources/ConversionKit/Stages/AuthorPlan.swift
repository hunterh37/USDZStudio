import Foundation
import simd
import USDCore

/// Precomputed animation/skinning authoring state derived from an
/// `IntermediateScene`. Owns the joint-hierarchy math, timeline sampling, and
/// Skeleton/SkelAnimation prim construction so `USDAuthorStage` stays a thin
/// tree walk. Only the first animation clip is authored (the stage warns about
/// the rest); a shared 24fps timeline maps key seconds → time codes.
struct AuthorPlan {
    let scene: IntermediateScene
    let rootPath: PrimPath
    var diagnostics: [Diagnostic] = []

    private let fps: Double = USDAuthorStage.defaultFPS
    private let animation: Animation?
    /// nodeID → path → sampler, for the authored clip.
    private let channels: [Int: [AnimationPath: AnimationSampler]]
    /// child nodeID → parent nodeID, across the whole scene.
    private let parentOf: [Int: Int]
    private let nodesByID: [Int: SceneNode]
    private let jointNodeIDs: Set<Int>
    /// skin index → authored Skeleton path.
    private let skeletonPaths: [Int: PrimPath]

    init(scene: IntermediateScene, rootPath: PrimPath) {
        self.scene = scene
        self.rootPath = rootPath
        self.nodesByID = scene.nodesByID()

        var parents: [Int: Int] = [:]
        for node in scene.rootNodes { Self.collectParents(node, into: &parents) }
        self.parentOf = parents

        let clip = scene.animations.first
        self.animation = clip
        var byNode: [Int: [AnimationPath: AnimationSampler]] = [:]
        if let clip {
            for channel in clip.channels where clip.samplers.indices.contains(channel.samplerIndex) {
                byNode[channel.targetNodeID, default: [:]][channel.path] = clip.samplers[channel.samplerIndex]
            }
        }
        self.channels = byNode

        var joints: Set<Int> = []
        for skin in scene.skins { joints.formUnion(skin.joints) }
        self.jointNodeIDs = joints

        // Assign a unique, USD-legal Skeleton name per skin.
        var used: Set<String> = ["Materials"]
        var paths: [Int: PrimPath] = [:]
        for (index, skin) in scene.skins.enumerated() {
            var name = USDNameSanitizer.sanitize(skin.name.isEmpty ? "Skeleton_\(index)" : skin.name)
            while used.contains(name) { name += "_1" }
            used.insert(name)
            paths[index] = rootPath.appending(name)!
        }
        self.skeletonPaths = paths
    }

    // MARK: - Queries used by the stage

    var isSkinned: Bool { !scene.skins.isEmpty }

    func skeletonPath(forSkin index: Int) -> PrimPath? { skeletonPaths[index] }

    private var hasTimeline: Bool { (animation?.duration ?? 0) > 0 }

    var timeCodesPerSecond: Double? { hasTimeline ? fps : nil }
    var startTimeCode: Double? { hasTimeline ? 0 : nil }
    var endTimeCode: Double? { hasTimeline ? Double(animation!.duration) * fps : nil }

    /// For a non-joint animated node, a single time-sampled `xformOp:transform`
    /// (plus its `xformOpOrder`); `nil` when the node isn't animated as a plain
    /// transform (no channels, or it's a skeleton joint the Skeleton drives).
    func nodeTransformOps(for node: SceneNode) -> [Attribute]? {
        guard let id = node.id, !jointNodeIDs.contains(id), let ch = channels[id], !ch.isEmpty else {
            return nil
        }
        let times = unionTimes(for: [ch])
        guard !times.isEmpty else { return nil }
        let rest = Self.decompose(node.transform)
        let samples = times.map { t -> TimeSample in
            let translation = ch[.translation]?.sampledVec3(at: t) ?? rest.translation
            let rotation = ch[.rotation]?.sampledQuat(at: t) ?? rest.rotation
            let scale = ch[.scale]?.sampledVec3(at: t) ?? rest.scale
            let matrix = Self.compose(translation: translation, rotation: rotation, scale: scale)
            return TimeSample(time: Double(t) * fps, value: .matrix4(USDAuthorStage.rowMajor(matrix)))
        }
        return [
            Attribute(name: "xformOp:transform", value: .matrix4(USDAuthorStage.rowMajor(node.transform)), timeSamples: samples),
        ]
    }

    // MARK: - Skeleton / SkelAnimation prims

    mutating func skeletonPrims() -> [Prim] {
        var prims: [Prim] = []
        for (index, skin) in scene.skins.enumerated() {
            guard let path = skeletonPaths[index] else { continue }
            prims.append(skeletonPrim(skin, index: index, path: path))
        }
        return prims
    }

    private mutating func skeletonPrim(_ skin: Skin, index: Int, path: PrimPath) -> Prim {
        let jointPaths = skin.joints.map { jointTokenPath($0, in: Set(skin.joints)) }
        var bind: [Double] = []
        var rest: [Double] = []
        for (i, jointID) in skin.joints.enumerated() {
            let world = skin.inverseBindMatrices.indices.contains(i)
                ? skin.inverseBindMatrices[i].inverse : matrix_identity_float4x4
            bind.append(contentsOf: USDAuthorStage.rowMajor(world))
            let local = nodesByID[jointID]?.transform ?? matrix_identity_float4x4
            rest.append(contentsOf: USDAuthorStage.rowMajor(local))
        }

        let attributes = [
            Attribute(name: "joints", value: .tokenArray(jointPaths), isUniform: true),
            Attribute(name: "bindTransforms", value: .matrix4dArray(bind), isUniform: true),
            Attribute(name: "restTransforms", value: .matrix4dArray(rest), isUniform: true),
        ]
        var relationships: [Relationship] = []
        var children: [Prim] = []
        if let animPrim = skelAnimationPrim(for: skin, under: path) {
            children.append(animPrim)
            relationships.append(Relationship(name: "skel:animationSource", targets: [animPrim.path]))
        }
        return Prim(path: path, typeName: "Skeleton", attributes: attributes,
                    relationships: relationships, children: children)
    }

    private mutating func skelAnimationPrim(for skin: Skin, under skeleton: PrimPath) -> Prim? {
        let jointSet = Set(skin.joints)
        // Joints that carry at least one transform channel.
        let animated = skin.joints.enumerated().filter { channels[$0.element]?.isEmpty == false }
        guard !animated.isEmpty else { return nil }

        let perJointChannels = animated.map { channels[$0.element]! }
        let times = unionTimes(for: perJointChannels)
        guard !times.isEmpty else { return nil }

        let jointTokens = animated.map { jointTokenPath($0.element, in: jointSet) }
        var translationSamples: [TimeSample] = []
        var rotationSamples: [TimeSample] = []
        var scaleSamples: [TimeSample] = []

        for t in times {
            var translations: [Double] = []
            var rotations: [Double] = []
            var scales: [Double] = []
            for (_, jointID) in animated {
                let ch = channels[jointID] ?? [:]
                let rest = Self.decompose(nodesByID[jointID]?.transform ?? matrix_identity_float4x4)
                let tr = ch[.translation]?.sampledVec3(at: t) ?? rest.translation
                let rot = ch[.rotation]?.sampledQuat(at: t) ?? rest.rotation  // xyzw
                let sc = ch[.scale]?.sampledVec3(at: t) ?? rest.scale
                translations.append(contentsOf: [Double(tr.x), Double(tr.y), Double(tr.z)])
                // USD quatf is (w, x, y, z); our sampler yields (x, y, z, w).
                rotations.append(contentsOf: [Double(rot.w), Double(rot.x), Double(rot.y), Double(rot.z)])
                scales.append(contentsOf: [Double(sc.x), Double(sc.y), Double(sc.z)])
            }
            let tc = Double(t) * fps
            translationSamples.append(TimeSample(time: tc, value: .float3Array(translations)))
            rotationSamples.append(TimeSample(time: tc, value: .quatfArray(rotations)))
            scaleSamples.append(TimeSample(time: tc, value: .float3Array(scales)))
        }

        if animated.contains(where: { channels[$0.element]?[.weights] != nil }) {
            diagnostics.append(Diagnostic(
                severity: .warning, stage: "usd-author",
                message: "\(skin.name): morph-target (weights) animation is not authored as BlendShapes yet"))
        }

        let animPath = skeleton.appending("Anim")!
        return Prim(path: animPath, typeName: "SkelAnimation", attributes: [
            Attribute(name: "joints", value: .tokenArray(jointTokens), isUniform: true),
            Attribute(name: "translations", value: .float3Array([]), timeSamples: translationSamples),
            Attribute(name: "rotations", value: .quatfArray([]), timeSamples: rotationSamples),
            Attribute(name: "scales", value: .float3Array([]), timeSamples: scaleSamples),
        ])
    }

    // MARK: - Joint hierarchy

    /// The Skeleton-relative `token` path of a joint, e.g. `Hips/Spine/Chest`,
    /// walking up the parent chain while ancestors remain in the joint set.
    private func jointTokenPath(_ id: Int, in jointSet: Set<Int>) -> String {
        var components: [String] = []
        var current: Int? = id
        while let c = current, let node = nodesByID[c] {
            components.insert(USDNameSanitizer.sanitize(node.name), at: 0)
            if let parent = parentOf[c], jointSet.contains(parent) { current = parent } else { break }
        }
        return components.joined(separator: "/")
    }

    private static func collectParents(_ node: SceneNode, into map: inout [Int: Int]) {
        for child in node.children {
            if let cid = child.id, let pid = node.id { map[cid] = pid }
            collectParents(child, into: &map)
        }
    }

    // MARK: - Sampling / TRS math

    /// Sorted, de-duplicated key times (seconds) across the given channel maps.
    private func unionTimes(for channelMaps: [[AnimationPath: AnimationSampler]]) -> [Float] {
        var set: Set<Float> = []
        for map in channelMaps {
            for sampler in map.values { set.formUnion(sampler.input) }
        }
        return set.sorted()
    }

    /// Decomposes a column-major affine matrix into T/R(xyzw)/S.
    static func decompose(_ m: simd_float4x4) -> (translation: SIMD3<Float>, rotation: SIMD4<Float>, scale: SIMD3<Float>) {
        let translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let scale = SIMD3(simd_length(c0), simd_length(c1), simd_length(c2))
        let rot = simd_float3x3(
            scale.x > 0 ? c0 / scale.x : SIMD3(1, 0, 0),
            scale.y > 0 ? c1 / scale.y : SIMD3(0, 1, 0),
            scale.z > 0 ? c2 / scale.z : SIMD3(0, 0, 1))
        let q = simd_quatf(rot)
        return (translation, SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real), scale)
    }

    /// Composes T * R(xyzw quaternion) * S into a column-major matrix.
    static func compose(translation: SIMD3<Float>, rotation: SIMD4<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        let q = simd_quatf(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w)
        var m = simd_float4x4(q)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return m
    }
}

// MARK: - Sampler evaluation

extension AnimationSampler {
    /// Linearly (or STEP-) interpolated vec3 at time `t`, clamped at the ends.
    func sampledVec3(at t: Float) -> SIMD3<Float>? {
        guard case .vec3(let values) = output, !values.isEmpty else { return nil }
        let (a, b, f) = locate(t, count: values.count)
        if interpolation == .step || a == b { return values[a] }
        return values[a] + (values[b] - values[a]) * f
    }

    /// Normalized, shortest-path (n)lerp quaternion (xyzw) at time `t`.
    func sampledQuat(at t: Float) -> SIMD4<Float>? {
        guard case .rotation(let values) = output, !values.isEmpty else { return nil }
        let (a, b, f) = locate(t, count: values.count)
        if interpolation == .step || a == b { return simd_normalize(values[a]) }
        var qb = values[b]
        if simd_dot(values[a], qb) < 0 { qb = -qb }
        return simd_normalize(values[a] + (qb - values[a]) * f)
    }

    /// Bracketing key indices and blend factor for `t` over `count` outputs.
    private func locate(_ t: Float, count: Int) -> (Int, Int, Float) {
        let n = Swift.min(input.count, count)
        guard n > 1 else { return (0, 0, 0) }
        if t <= input[0] { return (0, 0, 0) }
        if t >= input[n - 1] { return (n - 1, n - 1, 0) }
        // Key times are sorted, so binary-search the bracketing interval rather
        // than scanning linearly. Authoring evaluates every joint at the union
        // of all key times, so a linear scan here is O(keys²) per channel.
        // `lo` lands on the first key strictly greater than `t`; `t` is strictly
        // inside (0, n-1) here, so `lo ∈ [1, n-1]` and `lo - 1` is its bracket.
        var lo = 1, hi = n - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if input[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        let span = input[i + 1] - input[i]
        let f = span > 0 ? (t - input[i]) / span : 0
        return (i, i + 1, f)
    }
}
