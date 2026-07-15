import Foundation
import simd

/// Severity of a pipeline diagnostic. Unsupported features produce
/// warnings, never silent drops (specs/conversion-pipeline.md).
public enum DiagnosticSeverity: String, Hashable, Sendable, Codable {
    case info
    case warning
    case error
}

/// A named, attributable message emitted by an importer or stage.
public struct Diagnostic: Hashable, Sendable {
    public var severity: DiagnosticSeverity
    public var stage: String
    public var message: String

    public init(severity: DiagnosticSeverity, stage: String, message: String) {
        self.severity = severity
        self.stage = stage
        self.message = message
    }
}

/// Where a texture's bytes live before the texture pipeline runs.
public enum TextureSource: Hashable, Sendable {
    /// External file, relative to the source asset.
    case uri(String)
    /// Bytes embedded in the source container (GLB BIN chunk, data URI).
    case data(Data)
}

/// A texture reference produced by an importer.
public struct TextureRef: Hashable, Sendable {
    public var source: TextureSource
    public var mimeType: String?

    public init(source: TextureSource, mimeType: String? = nil) {
        self.source = source
        self.mimeType = mimeType
    }
}

/// glTF-style alpha handling, mapped later to opacity/opacityThreshold.
public enum AlphaMode: Hashable, Sendable {
    case opaque
    case mask(threshold: Float)
    case blend
}

/// Format-agnostic PBR metallic-roughness material (maps 1:1 onto
/// UsdPreviewSurface per the table in specs/conversion-pipeline.md).
public struct PBRMaterial: Hashable, Sendable {
    public var name: String
    public var baseColorFactor: SIMD4<Float>
    public var baseColorTexture: TextureRef?
    public var metallicFactor: Float
    public var roughnessFactor: Float
    public var metallicRoughnessTexture: TextureRef?
    public var normalTexture: TextureRef?
    public var normalScale: Float
    public var occlusionTexture: TextureRef?
    public var emissiveFactor: SIMD3<Float>
    public var emissiveTexture: TextureRef?
    public var alphaMode: AlphaMode
    public var doubleSided: Bool

    public init(
        name: String = "Material",
        baseColorFactor: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        baseColorTexture: TextureRef? = nil,
        metallicFactor: Float = 1,
        roughnessFactor: Float = 1,
        metallicRoughnessTexture: TextureRef? = nil,
        normalTexture: TextureRef? = nil,
        normalScale: Float = 1,
        occlusionTexture: TextureRef? = nil,
        emissiveFactor: SIMD3<Float> = SIMD3(0, 0, 0),
        emissiveTexture: TextureRef? = nil,
        alphaMode: AlphaMode = .opaque,
        doubleSided: Bool = false
    ) {
        self.name = name
        self.baseColorFactor = baseColorFactor
        self.baseColorTexture = baseColorTexture
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
        self.metallicRoughnessTexture = metallicRoughnessTexture
        self.normalTexture = normalTexture
        self.normalScale = normalScale
        self.occlusionTexture = occlusionTexture
        self.emissiveFactor = emissiveFactor
        self.emissiveTexture = emissiveTexture
        self.alphaMode = alphaMode
        self.doubleSided = doubleSided
    }
}

/// Triangulated mesh data. Indices always index triangles (mode 4);
/// importers emit warnings and skip other primitive modes.
public struct MeshData: Hashable, Sendable {
    public var name: String
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var uvs: [SIMD2<Float>]
    public var indices: [UInt32]
    /// Index into `IntermediateScene.materials`, or nil for the default material.
    public var materialIndex: Int?
    /// Per-vertex skinning influences (glTF JOINTS_0). Each element holds up to
    /// four joint indices into the binding skin's `joints`. Empty when unskinned.
    public var jointIndices: [SIMD4<UInt16>]
    /// Per-vertex skinning weights (glTF WEIGHTS_0), parallel to `jointIndices`.
    public var jointWeights: [SIMD4<Float>]

    public init(
        name: String = "Mesh",
        positions: [SIMD3<Float>] = [],
        normals: [SIMD3<Float>] = [],
        uvs: [SIMD2<Float>] = [],
        indices: [UInt32] = [],
        materialIndex: Int? = nil,
        jointIndices: [SIMD4<UInt16>] = [],
        jointWeights: [SIMD4<Float>] = []
    ) {
        self.name = name
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
        self.materialIndex = materialIndex
        self.jointIndices = jointIndices
        self.jointWeights = jointWeights
    }

    public var triangleCount: Int { indices.count / 3 }

    /// `true` when the mesh carries per-vertex skinning influences.
    public var isSkinned: Bool { !jointIndices.isEmpty }
}

/// A node in the scene hierarchy. Value-typed tree, like `Prim`.
public struct SceneNode: Hashable, Sendable {
    public var name: String
    /// Local transform, column-major.
    public var transform: simd_float4x4
    /// Indices into `IntermediateScene.meshes`.
    public var meshIndices: [Int]
    public var children: [SceneNode]
    /// Stable importer-assigned identity (glTF node index). Animation channels
    /// and skin joints target nodes by this id; `nil` for synthesized nodes.
    public var id: Int?
    /// Index into `IntermediateScene.skins` when this node instantiates a
    /// skinned mesh (glTF `node.skin`); `nil` otherwise.
    public var skinIndex: Int?

    public init(
        name: String = "Node",
        transform: simd_float4x4 = matrix_identity_float4x4,
        meshIndices: [Int] = [],
        children: [SceneNode] = [],
        id: Int? = nil,
        skinIndex: Int? = nil
    ) {
        self.name = name
        self.transform = transform
        self.meshIndices = meshIndices
        self.children = children
        self.id = id
        self.skinIndex = skinIndex
    }

    /// Depth-first traversal of this node and all descendants.
    public func flattened() -> [SceneNode] {
        [self] + children.flatMap { $0.flattened() }
    }
}

extension simd_float4x4: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        for column in [columns.0, columns.1, columns.2, columns.3] {
            hasher.combine(column)
        }
    }
}

/// ConversionKit's internal representation: importers produce it, stages
/// transform it, the USD author stage consumes it. Decouples N input
/// formats from the single writer (specs/conversion-pipeline.md).
public struct IntermediateScene: Hashable, Sendable {
    public var name: String
    public var rootNodes: [SceneNode]
    public var meshes: [MeshData]
    public var materials: [PBRMaterial]
    public var skins: [Skin]
    public var animations: [Animation]

    public init(
        name: String = "Scene",
        rootNodes: [SceneNode] = [],
        meshes: [MeshData] = [],
        materials: [PBRMaterial] = [],
        skins: [Skin] = [],
        animations: [Animation] = []
    ) {
        self.name = name
        self.rootNodes = rootNodes
        self.meshes = meshes
        self.materials = materials
        self.skins = skins
        self.animations = animations
    }

    /// Every node in the scene keyed by its importer id, for channel/joint
    /// resolution during authoring.
    public func nodesByID() -> [Int: SceneNode] {
        var map: [Int: SceneNode] = [:]
        for node in allNodes() where node.id != nil { map[node.id!] = node }
        return map
    }

    /// Every node in the scene, depth-first.
    public func allNodes() -> [SceneNode] {
        rootNodes.flatMap { $0.flattened() }
    }

    /// Total triangles across all meshes (batch-report metric).
    public var triangleCount: Int {
        meshes.reduce(0) { $0 + $1.triangleCount }
    }
}

// MARK: - Skinning & animation

/// A skin binds a set of joint nodes and their inverse bind matrices to skinned
/// meshes (glTF `skin` → UsdSkel `Skeleton`).
public struct Skin: Hashable, Sendable {
    public var name: String
    /// Node ids (see `SceneNode.id`) of the joints, in binding order. A mesh's
    /// per-vertex `jointIndices` index into this array.
    public var joints: [Int]
    /// One inverse-bind matrix per joint (column-major), or empty when the glTF
    /// omitted the accessor (identity implied).
    public var inverseBindMatrices: [simd_float4x4]
    /// Node id of the common skeleton root, if the glTF declared one.
    public var skeletonRoot: Int?

    public init(
        name: String = "Skin",
        joints: [Int] = [],
        inverseBindMatrices: [simd_float4x4] = [],
        skeletonRoot: Int? = nil
    ) {
        self.name = name
        self.joints = joints
        self.inverseBindMatrices = inverseBindMatrices
        self.skeletonRoot = skeletonRoot
    }
}

/// Keyframe interpolation mode for an animation sampler (glTF sampler
/// `interpolation`). CUBICSPLINE tangents are not authored; the importer warns
/// and treats such samplers as LINEAR (no silent drop).
public enum Interpolation: String, Hashable, Sendable {
    case linear = "LINEAR"
    case step = "STEP"
    case cubicSpline = "CUBICSPLINE"
}

/// Which node property an animation channel drives.
public enum AnimationPath: Hashable, Sendable {
    case translation
    case rotation
    case scale
    /// Morph-target weights — parsed for completeness but not yet authored as
    /// UsdSkel BlendShapes (the author stage warns).
    case weights
}

/// The time-indexed output of one channel: input times paired with typed
/// outputs. Translations/scales are vec3; rotations are quaternions (xyzw);
/// weights are scalars flattened per keyframe.
public struct AnimationSampler: Hashable, Sendable {
    public enum Output: Hashable, Sendable {
        case vec3([SIMD3<Float>])
        case rotation([SIMD4<Float>])  // quaternion xyzw
        case scalar([Float])
    }

    public var input: [Float]  // key times, seconds
    public var interpolation: Interpolation
    public var output: Output

    public init(input: [Float], interpolation: Interpolation, output: Output) {
        self.input = input
        self.interpolation = interpolation
        self.output = output
    }
}

/// A single channel: sampler → (target node, property).
public struct AnimationChannel: Hashable, Sendable {
    public var targetNodeID: Int
    public var path: AnimationPath
    public var samplerIndex: Int

    public init(targetNodeID: Int, path: AnimationPath, samplerIndex: Int) {
        self.targetNodeID = targetNodeID
        self.path = path
        self.samplerIndex = samplerIndex
    }
}

/// A named animation clip (glTF `animation`): channels reference samplers.
public struct Animation: Hashable, Sendable {
    public var name: String
    public var channels: [AnimationChannel]
    public var samplers: [AnimationSampler]

    public init(name: String = "Animation", channels: [AnimationChannel] = [], samplers: [AnimationSampler] = []) {
        self.name = name
        self.channels = channels
        self.samplers = samplers
    }

    /// The largest key time across all samplers (clip duration, seconds).
    public var duration: Float {
        samplers.flatMap(\.input).max() ?? 0
    }
}
