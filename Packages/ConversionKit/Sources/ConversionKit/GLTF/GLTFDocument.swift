import Foundation

/// Codable subset of the glTF 2.0 JSON schema — only what the importer
/// consumes. Unknown fields are ignored by design; unknown *extensions*
/// are surfaced as warnings by the importer (spec: no silent drops).
struct GLTFDocument: Decodable {
    struct Asset: Decodable {
        var version: String
    }

    struct Scene: Decodable {
        var name: String?
        var nodes: [Int]?
    }

    struct Node: Decodable {
        var name: String?
        var children: [Int]?
        var mesh: Int?
        /// Index into `skins` when this node instantiates a skinned mesh.
        var skin: Int?
        /// Column-major 16 floats; mutually exclusive with TRS.
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?  // quaternion x,y,z,w
        var scale: [Float]?
    }

    struct Mesh: Decodable {
        var name: String?
        var primitives: [Primitive]
    }

    struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?  // default 4 = TRIANGLES
    }

    struct Buffer: Decodable {
        var uri: String?
        var byteLength: Int
    }

    struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }

    struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String  // SCALAR, VEC2, VEC3, VEC4, MAT4…
    }

    struct Image: Decodable {
        var uri: String?
        var mimeType: String?
        var bufferView: Int?
    }

    struct Texture: Decodable {
        var source: Int?
    }

    struct TextureInfo: Decodable {
        var index: Int
        var scale: Float?     // normalTexture only
        var strength: Float?  // occlusionTexture only
    }

    struct PBRMetallicRoughness: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float?
        var roughnessFactor: Float?
        var metallicRoughnessTexture: TextureInfo?
    }

    struct Material: Decodable {
        var name: String?
        var pbrMetallicRoughness: PBRMetallicRoughness?
        var normalTexture: TextureInfo?
        var occlusionTexture: TextureInfo?
        var emissiveTexture: TextureInfo?
        var emissiveFactor: [Float]?
        var alphaMode: String?
        var alphaCutoff: Float?
        var doubleSided: Bool?
    }

    struct Skin: Decodable {
        var name: String?
        var joints: [Int]
        var inverseBindMatrices: Int?
        var skeleton: Int?
    }

    struct Animation: Decodable {
        struct Sampler: Decodable {
            var input: Int   // accessor of key times (SCALAR float)
            var output: Int  // accessor of values
            var interpolation: String?  // LINEAR (default), STEP, CUBICSPLINE
        }
        struct Channel: Decodable {
            struct Target: Decodable {
                var node: Int?
                var path: String  // translation | rotation | scale | weights
            }
            var sampler: Int
            var target: Target
        }
        var name: String?
        var channels: [Channel]
        var samplers: [Sampler]
    }

    var asset: Asset
    var scene: Int?
    var scenes: [Scene]?
    var nodes: [Node]?
    var meshes: [Mesh]?
    var buffers: [Buffer]?
    var bufferViews: [BufferView]?
    var accessors: [Accessor]?
    var images: [Image]?
    var textures: [Texture]?
    var materials: [Material]?
    var skins: [Skin]?
    var animations: [Animation]?
    var extensionsUsed: [String]?
    var extensionsRequired: [String]?
}
