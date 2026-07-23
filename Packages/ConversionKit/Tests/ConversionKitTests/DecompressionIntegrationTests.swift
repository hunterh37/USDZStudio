import Foundation
import simd
import Testing
@testable import ConversionKit

// MARK: - Test doubles

/// Thread-safe recorder so a `Sendable` fake codec can capture what the importer
/// handed it for later assertions.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func record(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    var last: T? { values.last }
}

private struct FakeGeometryDecompressor: GeometryDecompressor {
    let handler: @Sendable (CompressedPrimitive) throws -> DecodedGeometry
    func decode(_ primitive: CompressedPrimitive) throws -> DecodedGeometry { try handler(primitive) }
}

private struct FakeBufferViewDecompressor: BufferViewDecompressor {
    let handler: @Sendable (MeshoptBufferView) throws -> Data
    func decode(_ view: MeshoptBufferView) throws -> Data { try handler(view) }
}

private struct FakeTextureTranscoder: TextureTranscoder {
    let handler: @Sendable (Data, TextureColorSpace) throws -> DecodedImage
    func transcode(_ ktx2: Data, usage: TextureColorSpace) throws -> DecodedImage { try handler(ktx2, usage) }
}

/// Runs `body` and returns the thrown error (or nil) so case + payload can be
/// asserted without pinning the exact human-readable detail string.
private func captureError(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); return nil } catch { return error }
}

private let options = ImportOptions()

// MARK: - Draco geometry

@Suite struct DracoDecodeTests {

    /// A GLB whose single triangle primitive is Draco-compressed. The accessors
    /// carry only count hints; geometry comes from the injected decoder.
    private func dracoTriangleGLB(
        positionAccessorCount: Int = 3,
        indexAccessorCount: Int? = 3,
        materialIndex: Int? = 0,
        includePositionHint: Bool = true
    ) -> Data {
        let positionAttr = includePositionHint ? "\"POSITION\":0," : ""
        let indices = indexAccessorCount != nil ? "\"indices\":3," : ""
        let material = materialIndex != nil ? "\"material\":\(materialIndex!)," : ""
        let json = """
        {
          "asset":{"version":"2.0"},
          "extensionsUsed":["KHR_draco_mesh_compression"],
          "extensionsRequired":["KHR_draco_mesh_compression"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"name":"Tri","primitives":[{
             "attributes":{\(positionAttr)"NORMAL":1,"TEXCOORD_0":2},
             \(indices)\(material)
             "extensions":{"KHR_draco_mesh_compression":{"bufferView":0,"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2}}}}]}],
          "materials":[{"name":"M"}],
          "accessors":[
            {"componentType":5126,"count":\(positionAccessorCount),"type":"VEC3"},
            {"componentType":5126,"count":3,"type":"VEC3"},
            {"componentType":5126,"count":3,"type":"VEC2"},
            {"componentType":5125,"count":\(indexAccessorCount ?? 0),"type":"SCALAR"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8}],
          "buffers":[{"byteLength":8}]
        }
        """
        return GLTFFixtures.glb(json: json, bin: Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    private let decodedTriangle = DecodedGeometry(
        positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
        normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
        uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
        indices: [0, 1, 2])

    @Test func decodesDracoPrimitiveIntoIntermediateScene() async throws {
        let recorder = Recorder<CompressedPrimitive>()
        let geometry = decodedTriangle
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { primitive in
                recorder.record(primitive)
                return geometry
            }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(), name: "draco-ok.glb")

        let result = try await importer.importAsset(at: url, options: options)

        let mesh = try #require(result.scene.meshes.first)
        #expect(result.scene.meshes.count == 1)
        #expect(mesh.name == "Tri")
        #expect(mesh.positions == decodedTriangle.positions)
        #expect(mesh.normals == decodedTriangle.normals)
        #expect(mesh.uvs == decodedTriangle.uvs)
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.materialIndex == 0)

        // The decoder received the raw stream and the glTF-declared hints.
        let passed = try #require(recorder.last)
        #expect(passed.data == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(passed.vertexCount == 3)
        #expect(passed.indexCount == 3)
        #expect(passed.attributeIDs == ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2])

        // Decode is announced, never silent.
        #expect(result.diagnostics.contains { $0.stage == "decode-compressed" && $0.message.contains("decoding KHR_draco_mesh_compression") })
        #expect(result.diagnostics.contains { $0.message.contains("Draco") && $0.message.contains("tris") })
    }

    @Test func carriesDecodedSkinningInfluences() async throws {
        let skinned = DecodedGeometry(
            positions: decodedTriangle.positions, indices: [0, 1, 2],
            jointIndices: [SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0)],
            jointWeights: [SIMD4(1, 0, 0, 0), SIMD4(0.5, 0.5, 0, 0), SIMD4(1, 0, 0, 0)])
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in skinned }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(), name: "draco-skin.glb")

        let mesh = try #require(try await importer.importAsset(at: url, options: options).scene.meshes.first)
        #expect(mesh.isSkinned)
        #expect(mesh.jointIndices.count == 3)
    }

    @Test func failsLoudlyWhenDecodedVertexCountMismatches() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in
                DecodedGeometry(positions: [SIMD3(0, 0, 0)], indices: [0])  // 1 vertex, hint says 3
            }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(), name: "draco-vmismatch.glb")

        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        guard case .decodeFailed(let ext, let detail)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed, got \(String(describing: error))"); return
        }
        #expect(ext == "KHR_draco_mesh_compression")
        #expect(detail.contains("1 vertices") && detail.contains("promised 3"))
    }

    @Test func failsLoudlyWhenDecodedIndexCountMismatches() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in
                DecodedGeometry(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2, 0, 1, 2])
            }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(), name: "draco-imismatch.glb")

        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        guard case .decodeFailed(_, let detail)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed, got \(String(describing: error))"); return
        }
        #expect(detail.contains("6 indices") && detail.contains("promised 3"))
    }

    @Test func toleratesDecodeWithNoIndexAccessor() async throws {
        // No `indices` accessor → the index-count hint is absent, so any decoded
        // index buffer is accepted as-is.
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in
                DecodedGeometry(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2])
            }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(indexAccessorCount: nil), name: "draco-noidx.glb")
        let mesh = try #require(try await importer.importAsset(at: url, options: options).scene.meshes.first)
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test func missingPositionHintOnDracoPrimitiveThrows() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in DecodedGeometry(positions: [], indices: []) }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(includePositionHint: false), name: "draco-nopos.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        #expect(error as? GLTFImporter.GLTFError == .missingPositions(mesh: "Tri"))
    }

    @Test func badMaterialIndexOnDracoPrimitiveThrows() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { _ in self.decodedTriangle }))
        let url = try GLTFFixtures.write(dracoTriangleGLB(materialIndex: 5), name: "draco-badmat.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        #expect(error as? GLTFImporter.GLTFError == .indexOutOfRange(what: "material", index: 5))
    }

    @Test func defaultImporterFailsLoudlyOnDracoWithoutACodec() async throws {
        // No native binding linked → the unavailable decoder fails loudly rather
        // than dropping the geometry.
        let url = try GLTFFixtures.write(dracoTriangleGLB(), name: "draco-nocodec.glb")
        let error = await captureError { _ = try await GLTFImporter().importAsset(at: url, options: options) }
        guard case .decodeFailed(let ext, _)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed, got \(String(describing: error))"); return
        }
        #expect(ext == "KHR_draco_mesh_compression")
    }
}

// MARK: - meshopt buffer views

@Suite struct MeshoptDecodeTests {

    /// A GLB with a single triangle whose POSITION and index buffer views are
    /// both `EXT_meshopt_compression`. The fake decoder returns the expanded
    /// bytes the accessors then read normally.
    private func meshoptTriangleGLB(
        positionMode: String = "ATTRIBUTES",
        positionFilter: String = "NONE",
        compressedByteLength: Int = 4
    ) -> Data {
        let json = """
        {
          "asset":{"version":"2.0"},
          "extensionsUsed":["EXT_meshopt_compression"],
          "extensionsRequired":["EXT_meshopt_compression"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"name":"Tri","primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
          "accessors":[
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
          "bufferViews":[
            {"buffer":0,"byteOffset":0,"byteLength":12,"byteStride":12,
             "extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":0,"byteLength":\(compressedByteLength),"byteStride":12,"count":3,"mode":"\(positionMode)","filter":"\(positionFilter)"}}},
            {"buffer":0,"byteOffset":16,"byteLength":6,"byteStride":2,
             "extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":16,"byteLength":2,"byteStride":2,"count":3,"mode":"INDICES","filter":"NONE"}}}],
          "buffers":[{"byteLength":18}]
        }
        """
        // Compressed source bytes: 16 for the position stream region, then 2 for indices.
        var bin = Data(repeating: 0xAB, count: 16)
        bin.append(Data([0xCD, 0xCD]))
        return GLTFFixtures.glb(json: json, bin: bin)
    }

    private let decodedPositions = GLTFFixtures.floats([0, 0, 0, 1, 0, 0, 0, 1, 0])  // 36 bytes
    private let decodedIndices = GLTFFixtures.uint16s([0, 1, 2])                      // 6 bytes

    @Test func decodesMeshoptBufferViewsThenReadsAccessorsNormally() async throws {
        let recorder = Recorder<MeshoptBufferView>()
        let positions = decodedPositions
        let indices = decodedIndices
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { view in
                recorder.record(view)
                return view.mode == .indices ? indices : positions
            }))
        let url = try GLTFFixtures.write(meshoptTriangleGLB(), name: "meshopt-ok.glb")

        let result = try await importer.importAsset(at: url, options: options)
        let mesh = try #require(result.scene.meshes.first)
        #expect(mesh.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(mesh.indices == [0, 1, 2])

        // Both views were decoded with the spec-declared parameters.
        let modes = Set(recorder.values.map(\.mode))
        #expect(modes == [.attributes, .indices])
        let attr = try #require(recorder.values.first { $0.mode == .attributes })
        #expect(attr.count == 3 && attr.byteStride == 12 && attr.filter == .none)
        #expect(attr.data.count == 4)  // the compressed slice, not the fallback region
        #expect(result.diagnostics.contains { $0.message.contains("meshopt bufferView") })
    }

    @Test func decodesEachViewOnlyOnce() async throws {
        // Two accessors over the *same* meshopt view must decode it once (memoized).
        let calls = Recorder<MeshoptBufferView>()
        let positions = decodedPositions
        let json = """
        {
          "asset":{"version":"2.0"},"extensionsUsed":["EXT_meshopt_compression"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1}}]}],
          "accessors":[
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":12,"byteStride":12,
             "extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":0,"byteLength":4,"byteStride":12,"count":3,"mode":"ATTRIBUTES","filter":"NONE"}}}],
          "buffers":[{"byteLength":4}]
        }
        """
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { view in calls.record(view); return positions }))
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json, bin: Data(repeating: 1, count: 4)), name: "meshopt-once.glb")
        _ = try await importer.importAsset(at: url, options: options)
        #expect(calls.values.count == 1)
    }

    @Test func failsWhenDecodedByteCountIsWrong() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { _ in Data(repeating: 0, count: 8) }))  // expected 36
        let url = try GLTFFixtures.write(meshoptTriangleGLB(), name: "meshopt-shortbytes.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        guard case .decodeFailed(let ext, let detail)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed, got \(String(describing: error))"); return
        }
        #expect(ext == "EXT_meshopt_compression")
        #expect(detail.contains("expected 36 B"))
    }

    @Test func rejectsUnknownMeshoptMode() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { _ in Data() }))
        let url = try GLTFFixtures.write(meshoptTriangleGLB(positionMode: "BOGUS"), name: "meshopt-badmode.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        guard case .decodeFailed(_, let detail)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed"); return
        }
        #expect(detail.contains("unknown meshopt mode"))
    }

    @Test func rejectsUnknownMeshoptFilter() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { _ in Data() }))
        let url = try GLTFFixtures.write(meshoptTriangleGLB(positionFilter: "WEIRD"), name: "meshopt-badfilter.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        guard case .decodeFailed(_, let detail)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed"); return
        }
        #expect(detail.contains("unknown meshopt filter"))
    }

    @Test func rejectsCompressedSliceOutOfBounds() async throws {
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            bufferView: FakeBufferViewDecompressor { _ in Data() }))
        // Claim a 999-byte compressed region in an 18-byte buffer.
        let url = try GLTFFixtures.write(meshoptTriangleGLB(compressedByteLength: 999), name: "meshopt-oob.glb")
        let error = await captureError { _ = try await importer.importAsset(at: url, options: options) }
        #expect(error as? GLTFImporter.GLTFError == .bufferOutOfBounds(buffer: 0))
    }

    @Test func defaultImporterFailsLoudlyOnMeshoptWithoutACodec() async throws {
        let url = try GLTFFixtures.write(meshoptTriangleGLB(), name: "meshopt-nocodec.glb")
        let error = await captureError { _ = try await GLTFImporter().importAsset(at: url, options: options) }
        guard case .decodeFailed(let ext, _)? = error as? DecompressionError else {
            Issue.record("expected decodeFailed"); return
        }
        #expect(ext == "EXT_meshopt_compression")
    }

    @Test func decodesDracoStreamCarriedInAMeshoptBufferView() async throws {
        // Draco + meshopt combo: the Draco stream lives in a meshopt-compressed
        // view, so meshopt decodes first, then Draco consumes the result.
        let dracoStream = Data([9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9])  // 12 bytes "decoded"
        let receivedByDraco = Recorder<Data>()
        let json = """
        {
          "asset":{"version":"2.0"},"extensionsUsed":["KHR_draco_mesh_compression","EXT_meshopt_compression"],
          "extensionsRequired":["KHR_draco_mesh_compression","EXT_meshopt_compression"],
          "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
          "meshes":[{"name":"Combo","primitives":[{
            "attributes":{"POSITION":0},
            "extensions":{"KHR_draco_mesh_compression":{"bufferView":0,"attributes":{"POSITION":0}}}}]}],
          "accessors":[{"componentType":5126,"count":3,"type":"VEC3"}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":12,"byteStride":1,
            "extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":0,"byteLength":4,"byteStride":1,"count":12,"mode":"ATTRIBUTES","filter":"NONE"}}}],
          "buffers":[{"byteLength":4}]
        }
        """
        let importer = GLTFImporter(codecs: DecompressionCodecs(
            geometry: FakeGeometryDecompressor { primitive in
                receivedByDraco.record(primitive.data)
                return DecodedGeometry(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2])
            },
            bufferView: FakeBufferViewDecompressor { _ in dracoStream }))
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json, bin: Data(repeating: 7, count: 4)), name: "combo.glb")

        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.meshes.first?.positions.count == 3)
        #expect(receivedByDraco.last == dracoStream)  // Draco saw the meshopt-decoded bytes
    }
}
