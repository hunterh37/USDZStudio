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
        var extensions: Extensions?

        /// Per-primitive extension payloads the importer decodes.
        struct Extensions: Decodable {
            var KHR_draco_mesh_compression: DracoPrimitive?
        }

        /// `KHR_draco_mesh_compression`: geometry lives in `bufferView`, keyed
        /// by Draco attribute id rather than glTF accessor. The referenced
        /// accessors carry only type/count hints (spec: decoded data overrides).
        struct DracoPrimitive: Decodable {
            var bufferView: Int
            var attributes: [String: Int]
        }
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
        var extensions: Extensions?

        /// Per-bufferView extension payloads.
        struct Extensions: Decodable {
            var EXT_meshopt_compression: MeshoptCompression?
        }

        /// `EXT_meshopt_compression`: the *view's* bytes are produced by decoding
        /// this compressed stream (its own `buffer`/`byteOffset`/`byteLength`),
        /// not by slicing the plain buffer. `mode`/`filter` default per spec.
        struct MeshoptCompression: Decodable {
            var buffer: Int
            var byteOffset: Int?
            var byteLength: Int
            var byteStride: Int
            var count: Int
            var mode: String            // ATTRIBUTES | TRIANGLES | INDICES
            var filter: String?         // NONE (default) | OCTAHEDRAL | QUATERNION | EXPONENTIAL
        }
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
        var extensions: Extensions?

        /// Per-texture extension payloads.
        struct Extensions: Decodable {
            var KHR_texture_basisu: Basisu?
        }

        /// `KHR_texture_basisu`: `source` points at a KTX2 image that supersedes
        /// the fallback `texture.source` when the transcoder is available.
        struct Basisu: Decodable {
            var source: Int
        }
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
