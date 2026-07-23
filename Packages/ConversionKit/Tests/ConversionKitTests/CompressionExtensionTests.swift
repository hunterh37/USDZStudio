import Foundation
import Testing
@testable import ConversionKit

/// Pure, codec-free coverage of the extension-classification policy and the
/// decode value types — the routing brain of the `decode-compressed` stage.
@Suite struct CompressionExtensionTests {

    // MARK: Classification

    @Test func classifiesDecodableUsedExtensions() {
        let c = ExtensionClassification.classify(
            used: ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu"],
            required: nil)
        #expect(c.decodable == [.draco, .meshopt, .textureBasisu])
        #expect(c.unsupportedRequired.isEmpty)
        #expect(c.ignoredUsed.isEmpty)
    }

    @Test func flagsUnsupportedRequiredExtension() {
        let c = ExtensionClassification.classify(
            used: ["KHR_materials_variants"], required: ["KHR_materials_variants"])
        #expect(c.decodable.isEmpty)
        #expect(c.unsupportedRequired == ["KHR_materials_variants"])
        #expect(c.ignoredUsed.isEmpty)
    }

    @Test func ignoresUsedButNotRequiredUnknownExtension() {
        let c = ExtensionClassification.classify(
            used: ["KHR_materials_transmission"], required: nil)
        #expect(c.decodable.isEmpty)
        #expect(c.unsupportedRequired.isEmpty)
        #expect(c.ignoredUsed == ["KHR_materials_transmission"])
    }

    @Test func unionsRequiredNotListedInUsedPreservingOrder() {
        // Non-conformant asset: a required extension omitted from `used`. We
        // still bind it (and here reject it, being unsupported).
        let c = ExtensionClassification.classify(
            used: ["KHR_texture_basisu"], required: ["KHR_lights_punctual"])
        #expect(c.decodable == [.textureBasisu])
        #expect(c.unsupportedRequired == ["KHR_lights_punctual"])
    }

    @Test func deduplicatesRepeatedExtensionNames() {
        let c = ExtensionClassification.classify(
            used: ["KHR_texture_basisu", "KHR_texture_basisu"],
            required: ["KHR_texture_basisu"])
        #expect(c.decodable == [.textureBasisu])
    }

    @Test func handlesNilLists() {
        let c = ExtensionClassification.classify(used: nil, required: nil)
        #expect(c.decodable.isEmpty && c.unsupportedRequired.isEmpty && c.ignoredUsed.isEmpty)
    }

    @Test func preservesFirstSeenOrderAcrossCategories() {
        let c = ExtensionClassification.classify(
            used: ["EXT_meshopt_compression", "KHR_materials_transmission", "KHR_draco_mesh_compression"],
            required: ["KHR_materials_variants"])
        #expect(c.decodable == [.meshopt, .draco])
        #expect(c.ignoredUsed == ["KHR_materials_transmission"])
        #expect(c.unsupportedRequired == ["KHR_materials_variants"])
    }

    // MARK: Extension name tables

    @Test func decodableNamesCoverEveryCase() {
        #expect(CompressionExtension.decodableNames == Set([
            "KHR_draco_mesh_compression", "KHR_texture_basisu", "EXT_meshopt_compression"]))
        for ext in CompressionExtension.allCases {
            #expect(CompressionExtension.decodableNames.contains(ext.rawValue))
        }
    }

    @Test func toleratedNamesAreNotDecodable() {
        for name in CompressionExtension.toleratedNames {
            #expect(CompressionExtension(rawValue: name) == nil)
        }
    }

    // MARK: Value types

    @Test func meshoptDecodedByteCountIsCountTimesStride() {
        let v = MeshoptBufferView(data: Data([1, 2]), count: 4, byteStride: 12, mode: .attributes, filter: .none)
        #expect(v.decodedByteCount == 48)
    }

    @Test func decodedImageWellFormednessChecksByteCount() {
        #expect(DecodedImage(rgba: Data(repeating: 0, count: 16), width: 2, height: 2, colorSpace: .sRGB).isWellFormed)
        #expect(!DecodedImage(rgba: Data(repeating: 0, count: 15), width: 2, height: 2, colorSpace: .sRGB).isWellFormed)
        #expect(!DecodedImage(rgba: Data(), width: 0, height: 2, colorSpace: .linear).isWellFormed)
    }

    @Test func compressedPrimitiveAndDecodedGeometryAreEquatable() {
        let p = CompressedPrimitive(data: Data([9]), attributeIDs: ["POSITION": 0], vertexCount: 3, indexCount: 3)
        #expect(p == CompressedPrimitive(data: Data([9]), attributeIDs: ["POSITION": 0], vertexCount: 3, indexCount: 3))
        let g = DecodedGeometry(positions: [.zero], indices: [0])
        #expect(g == DecodedGeometry(positions: [.zero], indices: [0]))
        #expect(g != DecodedGeometry(positions: [.one], indices: [0]))
    }

    // MARK: Unavailable codecs fail loudly

    @Test func unavailableGeometryDecompressorThrowsSpecificError() {
        #expect(throws: DecompressionError.decodeFailed(
            extension: "KHR_draco_mesh_compression",
            detail: "no Draco decoder is linked in this build; rebuild with the libdraco binding")) {
            try UnavailableGeometryDecompressor().decode(
                CompressedPrimitive(data: Data(), attributeIDs: [:], vertexCount: 0, indexCount: nil))
        }
    }

    @Test func unavailableBufferViewDecompressorThrowsSpecificError() {
        #expect(throws: DecompressionError.decodeFailed(
            extension: "EXT_meshopt_compression",
            detail: "no meshopt decoder is linked in this build; rebuild with the meshoptimizer binding")) {
            try UnavailableBufferViewDecompressor().decode(
                MeshoptBufferView(data: Data(), count: 0, byteStride: 4, mode: .attributes, filter: .none))
        }
    }

    @Test func unavailableTextureTranscoderThrowsSpecificError() {
        #expect(throws: DecompressionError.decodeFailed(
            extension: "KHR_texture_basisu",
            detail: "no KTX2/Basis transcoder is linked in this build; rebuild with the libktx binding")) {
            try UnavailableTextureTranscoder().transcode(Data(), usage: .sRGB)
        }
    }

    @Test func defaultCodecsBundleIsAllUnavailable() {
        let codecs = DecompressionCodecs.unavailable
        #expect(throws: DecompressionError.self) {
            try codecs.geometry.decode(CompressedPrimitive(data: Data(), attributeIDs: [:], vertexCount: 0, indexCount: nil))
        }
        #expect(throws: DecompressionError.self) {
            try codecs.bufferView.decode(MeshoptBufferView(data: Data(), count: 0, byteStride: 1, mode: .indices, filter: .none))
        }
        #expect(throws: DecompressionError.self) {
            try codecs.texture.transcode(Data(), usage: .linear)
        }
    }
}
