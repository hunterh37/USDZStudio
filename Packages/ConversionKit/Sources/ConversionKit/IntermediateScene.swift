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

    public init(
        name: String = "Mesh",
        positions: [SIMD3<Float>] = [],
        normals: [SIMD3<Float>] = [],
        uvs: [SIMD2<Float>] = [],
        indices: [UInt32] = [],
        materialIndex: Int? = nil
    ) {
        self.name = name
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
        self.materialIndex = materialIndex
    }

    public var triangleCount: Int { indices.count / 3 }
}

/// A node in the scene hierarchy. Value-typed tree, like `Prim`.
public struct SceneNode: Hashable, Sendable {
    public var name: String
    /// Local transform, column-major.
    public var transform: simd_float4x4
    /// Indices into `IntermediateScene.meshes`.
    public var meshIndices: [Int]
    public var children: [SceneNode]

    public init(
        name: String = "Node",
        transform: simd_float4x4 = matrix_identity_float4x4,
        meshIndices: [Int] = [],
        children: [SceneNode] = []
    ) {
        self.name = name
        self.transform = transform
        self.meshIndices = meshIndices
        self.children = children
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

    public init(
        name: String = "Scene",
        rootNodes: [SceneNode] = [],
        meshes: [MeshData] = [],
        materials: [PBRMaterial] = []
    ) {
        self.name = name
        self.rootNodes = rootNodes
        self.meshes = meshes
        self.materials = materials
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
