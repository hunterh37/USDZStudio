import Foundation
import simd

// MARK: - Errors

/// A decode failure surfaced by the compression stage. Both cases are *loud*:
/// nothing compressed is ever dropped silently (specs/conversion-pipeline.md).
public enum DecompressionError: Error, Equatable, Sendable {
    /// `extensionsRequired` lists something we neither decode nor tolerate.
    /// The asset cannot be faithfully represented, so import fails.
    case unsupportedRequiredExtension(name: String)
    /// A decodable extension was present but its codec failed or is unavailable
    /// (e.g. the native binding is not linked in this build). Carries the
    /// extension name and a specific, human-readable detail.
    case decodeFailed(extension: String, detail: String)
}

// MARK: - Geometry (Draco)

/// One Draco-compressed primitive handed to a `GeometryDecompressor`: the raw
/// compressed byte slice plus the glTF-declared attribute→Draco-id map and the
/// vertex/index counts the accessors promise (used to validate the decode).
public struct CompressedPrimitive: Equatable, Sendable {
    /// The `KHR_draco_mesh_compression.bufferView` bytes, already meshopt-decoded
    /// if that bufferView was itself meshopt-compressed.
    public var data: Data
    /// glTF attribute semantic (`POSITION`, `NORMAL`, …) → Draco attribute id.
    public var attributeIDs: [String: Int]
    /// Vertex count promised by the POSITION accessor (validation target).
    public var vertexCount: Int
    /// Index count promised by the primitive's `indices` accessor, if any.
    public var indexCount: Int?

    public init(data: Data, attributeIDs: [String: Int], vertexCount: Int, indexCount: Int?) {
        self.data = data
        self.attributeIDs = attributeIDs
        self.vertexCount = vertexCount
        self.indexCount = indexCount
    }
}

/// Plain, dequantized geometry produced from a `CompressedPrimitive`. Mirrors
/// exactly the buffers `MeshData` carries so the importer can splice it in
/// without reshaping. All attributes are optional except positions/indices.
public struct DecodedGeometry: Equatable, Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var uvs: [SIMD2<Float>]
    public var indices: [UInt32]
    public var jointIndices: [SIMD4<UInt16>]
    public var jointWeights: [SIMD4<Float>]

    public init(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>] = [],
        uvs: [SIMD2<Float>] = [],
        indices: [UInt32],
        jointIndices: [SIMD4<UInt16>] = [],
        jointWeights: [SIMD4<Float>] = []
    ) {
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
        self.jointIndices = jointIndices
        self.jointWeights = jointWeights
    }
}

/// Seam for `KHR_draco_mesh_compression`. The real implementation binds
/// libdraco (Apache-2.0); orchestration is tested against fakes so this
/// protocol is the single line the coverage gate excludes.
public protocol GeometryDecompressor: Sendable {
    func decode(_ primitive: CompressedPrimitive) throws -> DecodedGeometry
}

// MARK: - Buffer views (meshopt)

/// The decode parameters for one `EXT_meshopt_compression` buffer view: the
/// compressed byte slice plus the `(count, byteStride, mode, filter)` tuple the
/// meshopt codec needs to expand it back to `count * byteStride` plain bytes.
public struct MeshoptBufferView: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case attributes = "ATTRIBUTES"
        case triangles = "TRIANGLES"
        case indices = "INDICES"
    }
    public enum Filter: String, Equatable, Sendable {
        case none = "NONE"
        case octahedral = "OCTAHEDRAL"
        case quaternion = "QUATERNION"
        case exponential = "EXPONENTIAL"
    }

    public var data: Data
    public var count: Int
    public var byteStride: Int
    public var mode: Mode
    public var filter: Filter

    public init(data: Data, count: Int, byteStride: Int, mode: Mode, filter: Filter) {
        self.data = data
        self.count = count
        self.byteStride = byteStride
        self.mode = mode
        self.filter = filter
    }

    /// Bytes a correct decode must produce (`count * byteStride`).
    public var decodedByteCount: Int { count * byteStride }
}

/// Seam for `EXT_meshopt_compression`. The real implementation binds
/// meshoptimizer (MIT). Returns the expanded, plain bytes for the buffer view.
public protocol BufferViewDecompressor: Sendable {
    func decode(_ view: MeshoptBufferView) throws -> Data
}

// MARK: - Textures (KTX2 / Basis)

/// An uncompressed image produced from a KTX2/Basis source: tightly-packed
/// RGBA8 (`width * height * 4` bytes, row-major, top-left origin) plus the
/// carried color space. The importer re-encodes this to PNG through the
/// existing codec before the texture stage runs.
public struct DecodedImage: Equatable, Sendable {
    public var rgba: Data
    public var width: Int
    public var height: Int
    public var colorSpace: TextureColorSpace

    public init(rgba: Data, width: Int, height: Int, colorSpace: TextureColorSpace) {
        self.rgba = rgba
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
    }

    /// `true` when `rgba` holds exactly `width * height * 4` bytes.
    public var isWellFormed: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}

/// Seam for `KHR_texture_basisu`. The real implementation binds libktx/Basis
/// (Apache-2.0), transcoding ETC1S/UASTC to RGBA8.
public protocol TextureTranscoder: Sendable {
    func transcode(_ ktx2: Data, usage: TextureColorSpace) throws -> DecodedImage
}

// MARK: - Unavailable defaults (the excluded native seam's stand-in)

/// The default decoders used when no native codec is linked. They never decode;
/// they fail *loudly* with a specific diagnostic so a compressed asset produces
/// a clear error rather than a silent drop. The real native bindings replace
/// these at the call site; every orchestration path around them is covered by
/// injecting fakes, so these types are the coverage-excluded seam.
public struct UnavailableGeometryDecompressor: GeometryDecompressor {
    public init() {}
    public func decode(_ primitive: CompressedPrimitive) throws -> DecodedGeometry {
        throw DecompressionError.decodeFailed(
            extension: CompressionExtension.draco.rawValue,
            detail: "no Draco decoder is linked in this build; rebuild with the libdraco binding")
    }
}

public struct UnavailableBufferViewDecompressor: BufferViewDecompressor {
    public init() {}
    public func decode(_ view: MeshoptBufferView) throws -> Data {
        throw DecompressionError.decodeFailed(
            extension: CompressionExtension.meshopt.rawValue,
            detail: "no meshopt decoder is linked in this build; rebuild with the meshoptimizer binding")
    }
}

public struct UnavailableTextureTranscoder: TextureTranscoder {
    public init() {}
    public func transcode(_ ktx2: Data, usage: TextureColorSpace) throws -> DecodedImage {
        throw DecompressionError.decodeFailed(
            extension: CompressionExtension.textureBasisu.rawValue,
            detail: "no KTX2/Basis transcoder is linked in this build; rebuild with the libktx binding")
    }
}

/// The bundle of codec seams the glTF importer decodes through. Defaults to the
/// unavailable (loud-fail) codecs; tests inject fakes and the production build
/// injects the native bindings. Grouping them keeps `GLTFImporter.init` to a
/// single optional parameter as more codecs are added.
public struct DecompressionCodecs: Sendable {
    public var geometry: any GeometryDecompressor
    public var bufferView: any BufferViewDecompressor
    public var texture: any TextureTranscoder

    public init(
        geometry: any GeometryDecompressor = UnavailableGeometryDecompressor(),
        bufferView: any BufferViewDecompressor = UnavailableBufferViewDecompressor(),
        texture: any TextureTranscoder = UnavailableTextureTranscoder()
    ) {
        self.geometry = geometry
        self.bufferView = bufferView
        self.texture = texture
    }

    /// The default set: every codec fails loudly until a native binding is
    /// linked. Used by `GLTFImporter()`'s zero-arg initializer.
    public static let unavailable = DecompressionCodecs()
}
