import Testing
import Foundation
import simd
@testable import ConversionKit

@Suite("GLTFImporter")
struct GLTFImporterTests {
    let importer = GLTFImporter()
    let options = ImportOptions()

    // MARK: Happy paths

    @Test func importsTriangleFromGLB() async throws {
        let glb = GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN())
        let url = try GLTFFixtures.write(glb, name: "triangle.glb")
        let result = try await importer.importAsset(at: url, options: options)
        let scene = result.scene

        #expect(scene.name == "triangle")
        #expect(result.diagnostics.isEmpty)
        #expect(scene.rootNodes.count == 1)

        let node = try #require(scene.rootNodes.first)
        #expect(node.name == "Tri Node")
        #expect(node.transform.columns.3 == SIMD4(1, 2, 3, 1))
        #expect(node.meshIndices == [0])

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Tri")
        #expect(mesh.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(mesh.normals == [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)])
        #expect(mesh.uvs == [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)])
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.triangleCount == 1)
        #expect(mesh.materialIndex == 0)

        let material = try #require(scene.materials.first)
        #expect(material.name == "Red")
        #expect(material.baseColorFactor == SIMD4(1, 0, 0, 1))
        #expect(material.metallicFactor == 0.25)
        #expect(material.roughnessFactor == 0.75)
        #expect(material.emissiveFactor == SIMD3(0.1, 0.2, 0.3))
        #expect(material.doubleSided)
        #expect(material.alphaMode == .opaque)
        #expect(scene.triangleCount == 1)
    }

    @Test func importsGLTFWithDataURIBuffer() async throws {
        let base64 = GLTFFixtures.triangleBIN().base64EncodedString()
        let json = GLTFFixtures.triangleJSON(bufferURI: "data:application/octet-stream;base64,\(base64)")
        let url = try GLTFFixtures.write(Data(json.utf8), name: "triangle.gltf")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.meshes.first?.indices == [0, 1, 2])
    }

    @Test func importsGLTFWithExternalBufferFile() async throws {
        let url = try GLTFFixtures.write(
            Data(GLTFFixtures.triangleJSON(bufferURI: "geo.bin").utf8), name: "triangle.gltf")
        try GLTFFixtures.triangleBIN().write(
            to: url.deletingLastPathComponent().appendingPathComponent("geo.bin"))
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.meshes.first?.positions.count == 3)
    }

    @Test func generatesSequentialIndicesWhenAbsent() async throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "scenes": [{"nodes": [0]}],
          "nodes": [{"mesh": 0}],
          "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
          "buffers": [{"byteLength": 36}],
          "bufferViews": [{"buffer": 0, "byteLength": 36}],
          "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}]
        }
        """
        let glb = GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats(GLTFFixtures.trianglePositions))
        let url = try GLTFFixtures.write(glb, name: "noindices.glb")
        let result = try await importer.importAsset(at: url, options: options)
        let mesh = try #require(result.scene.meshes.first)
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.normals.isEmpty && mesh.uvs.isEmpty)
        #expect(mesh.name == "Mesh_0")
        #expect(result.scene.rootNodes.first?.name == "Node_0")
        #expect(result.scene.rootNodes.first?.transform == matrix_identity_float4x4)
    }

    @Test func fallsBackToAllNodesWithoutScenes() async throws {
        let json = """
        {"asset": {"version": "2.0"}, "nodes": [{"name": "A"}, {"name": "B"}]}
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "noscene.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.rootNodes.map(\.name) == ["A", "B"])
    }

    @Test func buildsNodeHierarchyWithTRSAndMatrix() async throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "scene": 0,
          "scenes": [{"nodes": [0]}],
          "nodes": [
            {"name": "Parent", "children": [1, 2], "scale": [2, 2, 2]},
            {"name": "Rotated", "rotation": [0, 0, 0.7071068, 0.7071068]},
            {"name": "Matrixed", "matrix": [1,0,0,0, 0,1,0,0, 0,0,1,0, 5,6,7,1]}
          ]
        }
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "tree.glb")
        let result = try await importer.importAsset(at: url, options: options)
        let parent = try #require(result.scene.rootNodes.first)
        #expect(parent.children.map(\.name) == ["Rotated", "Matrixed"])
        #expect(parent.transform.columns.0.x == 2)
        #expect(abs(parent.children[0].transform.columns.0.y - 1) < 1e-5)  // 90° Z rotation
        #expect(parent.children[1].transform.columns.3 == SIMD4(5, 6, 7, 1))
        #expect(result.scene.allNodes().count == 3)
    }

    // MARK: Materials

    @Test func mapsAlphaModes() async throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "materials": [
            {"alphaMode": "MASK", "alphaCutoff": 0.75},
            {"alphaMode": "MASK"},
            {"alphaMode": "BLEND"},
            {"normalTexture": {"index": 0, "scale": 2.5}}
          ]
        }
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "alpha.glb")
        let result = try await importer.importAsset(at: url, options: options)
        let materials = result.scene.materials
        #expect(materials[0].alphaMode == .mask(threshold: 0.75))
        #expect(materials[1].alphaMode == .mask(threshold: 0.5))
        #expect(materials[2].alphaMode == .blend)
        #expect(materials[0].name == "Material_0")
        #expect(materials[3].normalScale == 2.5)
        // Normal texture points at a texture that doesn't exist → warning, not drop.
        #expect(materials[3].normalTexture == nil)
        #expect(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("unresolvable") })
    }

    @Test func resolvesTexturesFromBufferViewAndDataURI() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let json = """
        {
          "asset": {"version": "2.0"},
          "materials": [{
            "pbrMetallicRoughness": {
              "baseColorTexture": {"index": 0},
              "metallicRoughnessTexture": {"index": 1}
            },
            "emissiveTexture": {"index": 2},
            "occlusionTexture": {"index": 3},
            "normalTexture": {"index": 4}
          }],
          "textures": [{"source": 0}, {"source": 1}, {"source": 2}, {"source": 3}, {"source": 4}],
          "images": [
            {"bufferView": 0, "mimeType": "image/png"},
            {"uri": "data:image/png;base64,\(pngBytes.base64EncodedString())"},
            {"uri": "textures/emissive.png"},
            {"bufferView": 9},
            {"bufferView": 1}
          ],
          "buffers": [{"byteLength": 4}],
          "bufferViews": [{"buffer": 0, "byteLength": 4}, {"buffer": 0, "byteLength": 99}]
        }
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json, bin: pngBytes), name: "tex.glb")
        let result = try await importer.importAsset(at: url, options: options)
        let material = try #require(result.scene.materials.first)
        #expect(material.baseColorTexture == TextureRef(source: .data(pngBytes), mimeType: "image/png"))
        #expect(material.metallicRoughnessTexture?.source == .data(pngBytes))
        #expect(material.emissiveTexture == TextureRef(source: .uri("textures/emissive.png")))
        #expect(material.occlusionTexture == nil)
        #expect(material.normalTexture == nil)  // view overruns buffer → dropped with warning
        #expect(result.diagnostics.filter { $0.message.contains("no readable bytes") }.count == 2)
    }

    // MARK: Warnings

    @Test func warnsOnUnsupportedExtensionsModesAndAttributes() async throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "extensionsUsed": ["KHR_materials_transmission"],
          "scenes": [{"nodes": [0]}],
          "nodes": [{"mesh": 0}],
          "meshes": [{"name": "M", "primitives": [
            {"attributes": {"POSITION": 0, "COLOR_0": 0}},
            {"attributes": {"POSITION": 0}, "mode": 1}
          ]}],
          "buffers": [{"byteLength": 36}],
          "bufferViews": [{"buffer": 0, "byteLength": 36}],
          "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}]
        }
        """
        let glb = GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats(GLTFFixtures.trianglePositions))
        let url = try GLTFFixtures.write(glb, name: "warn.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.meshes.count == 1)  // mode-1 primitive skipped
        #expect(result.scene.meshes.first?.name == "M_0")  // multi-primitive naming
        let messages = result.diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("KHR_materials_transmission") })
        #expect(messages.contains { $0.contains("COLOR_0") })
        #expect(messages.contains { $0.contains("mode 1") })
    }

    // MARK: Errors

    @Test func rejectsUnreadableFile() async {
        await expectError(.unreadableFile("missing.glb")) {
            try await importer.importAsset(
                at: URL(fileURLWithPath: "/nonexistent/missing.glb"), options: options)
        }
    }

    @Test func rejectsTruncatedGLBHeader() async throws {
        let url = try GLTFFixtures.write(Data("glTF".utf8), name: "trunc.glb")
        await expectError(.notGLB) { try await importer.importAsset(at: url, options: options) }
    }

    @Test func rejectsWrongContainerVersion() async throws {
        var data = Data("glTF".utf8)
        data.append(GLTFFixtures.uint32LE(1))
        data.append(GLTFFixtures.uint32LE(12))
        let url = try GLTFFixtures.write(data, name: "v1.glb")
        await expectError(.unsupportedContainerVersion(1)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsGLBWithoutJSONChunk() async throws {
        var data = Data("glTF".utf8)
        data.append(GLTFFixtures.uint32LE(2))
        data.append(GLTFFixtures.uint32LE(20))
        data.append(GLTFFixtures.uint32LE(0))              // zero-length chunk
        data.append(GLTFFixtures.uint32LE(0x004E_4942))    // BIN only
        let url = try GLTFFixtures.write(data, name: "nojson.glb")
        await expectError(.missingJSONChunk) { try await importer.importAsset(at: url, options: options) }
    }

    @Test func rejectsChunkOverrunningFile() async throws {
        var data = Data("glTF".utf8)
        data.append(GLTFFixtures.uint32LE(2))
        data.append(GLTFFixtures.uint32LE(999))
        data.append(GLTFFixtures.uint32LE(500))            // claims 500 bytes, has none
        data.append(GLTFFixtures.uint32LE(0x4E4F_534A))
        let url = try GLTFFixtures.write(data, name: "overrun.glb")
        await expectError(.notGLB) { try await importer.importAsset(at: url, options: options) }
    }

    @Test func rejectsMalformedJSON() async throws {
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: "{not json"), name: "bad.glb")
        await #expect(throws: GLTFImporter.GLTFError.self) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsNonV2Asset() async throws {
        let url = try GLTFFixtures.write(
            GLTFFixtures.glb(json: #"{"asset": {"version": "1.0"}}"#), name: "v1json.glb")
        await expectError(.unsupportedVersion("1.0")) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsRequiredExtensions() async throws {
        let json = #"{"asset": {"version": "2.0"}, "extensionsRequired": ["KHR_draco_mesh_compression"]}"#
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "draco.glb")
        await expectError(.requiredExtensionUnsupported("KHR_draco_mesh_compression")) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsMeshWithoutPositions() async throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"name": "Empty", "primitives": [{"attributes": {}}]}]}
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "nopos.glb")
        await expectError(.missingPositions(mesh: "Empty")) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsDanglingIndices() async throws {
        // Node references a mesh that doesn't exist.
        let missingMesh = #"{"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 5}]}"#
        var url = try GLTFFixtures.write(GLTFFixtures.glb(json: missingMesh), name: "badmesh.glb")
        await expectError(.indexOutOfRange(what: "mesh", index: 5)) {
            try await importer.importAsset(at: url, options: options)
        }

        // Scene references a node that doesn't exist.
        let missingNode = #"{"asset": {"version": "2.0"}, "scenes": [{"nodes": [7]}]}"#
        url = try GLTFFixtures.write(GLTFFixtures.glb(json: missingNode), name: "badnode.glb")
        await expectError(.indexOutOfRange(what: "node", index: 7)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsNodeCycles() async throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}],
         "nodes": [{"name": "A", "children": [1]}, {"name": "B", "children": [0]}]}
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "cycle.glb")
        await expectError(.indexOutOfRange(what: "node", index: 0)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsMissingExternalBuffer() async throws {
        let url = try GLTFFixtures.write(
            Data(GLTFFixtures.triangleJSON(bufferURI: "absent.bin").utf8), name: "nobuf.gltf")
        await expectError(.missingBufferData(buffer: 0)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsGLTFWithoutBINOrURI() async throws {
        let url = try GLTFFixtures.write(Data(GLTFFixtures.triangleJSON().utf8), name: "nobin.gltf")
        await expectError(.missingBufferData(buffer: 0)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsShortBuffer() async throws {
        // BIN chunk shorter than declared byteLength (102).
        let glb = GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: Data([1, 2, 3, 4]))
        let url = try GLTFFixtures.write(glb, name: "short.glb")
        await expectError(.bufferOutOfBounds(buffer: 0)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsAccessorOverrunningView() async throws {
        let json = """
        {
          "asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
          "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
          "buffers": [{"byteLength": 12}],
          "bufferViews": [{"buffer": 0, "byteLength": 12}],
          "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}]
        }
        """
        let glb = GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats([0, 0, 0]))
        let url = try GLTFFixtures.write(glb, name: "overread.glb")
        await expectError(.bufferOutOfBounds(buffer: 0)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsWrongAccessorTypes() async throws {
        // POSITION accessor typed as ushort SCALAR.
        let json = """
        {
          "asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
          "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
          "buffers": [{"byteLength": 36}],
          "bufferViews": [{"buffer": 0, "byteLength": 36}],
          "accessors": [
            {"bufferView": 0, "componentType": 5123, "count": 3, "type": "SCALAR"},
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}
          ]
        }
        """
        let glb = GLTFFixtures.glb(json: json, bin: GLTFFixtures.floats(GLTFFixtures.trianglePositions))
        let url = try GLTFFixtures.write(glb, name: "badtypes.glb")
        await #expect(throws: GLTFImporter.GLTFError.self) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsDanglingMaterialAccessorViewAndBuffer() async throws {
        // Primitive references material 5 with no materials array.
        let badMaterial = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 5}]}],
         "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}]}
        """
        var url = try GLTFFixtures.write(
            GLTFFixtures.glb(json: badMaterial, bin: GLTFFixtures.floats(GLTFFixtures.trianglePositions)),
            name: "badmat.glb")
        await expectError(.indexOutOfRange(what: "material", index: 5)) {
            try await importer.importAsset(at: url, options: options)
        }

        // POSITION references accessor 9 which doesn't exist.
        let badAccessor = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 9}}]}]}
        """
        url = try GLTFFixtures.write(GLTFFixtures.glb(json: badAccessor), name: "badacc.glb")
        await expectError(.indexOutOfRange(what: "accessor", index: 9)) {
            try await importer.importAsset(at: url, options: options)
        }

        // Accessor has no bufferView.
        let noView = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
         "accessors": [{"componentType": 5126, "count": 3, "type": "VEC3"}]}
        """
        url = try GLTFFixtures.write(GLTFFixtures.glb(json: noView), name: "noview.glb")
        await expectError(.indexOutOfRange(what: "bufferView", index: -1)) {
            try await importer.importAsset(at: url, options: options)
        }

        // Accessor references bufferView 5 which doesn't exist.
        let badView = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
         "accessors": [{"bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC3"}]}
        """
        url = try GLTFFixtures.write(GLTFFixtures.glb(json: badView), name: "badview.glb")
        await expectError(.indexOutOfRange(what: "bufferView", index: 5)) {
            try await importer.importAsset(at: url, options: options)
        }

        // View references buffer 3 which doesn't exist.
        let badBuffer = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
         "bufferViews": [{"buffer": 3, "byteLength": 36}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}]}
        """
        url = try GLTFFixtures.write(GLTFFixtures.glb(json: badBuffer), name: "badbuf.glb")
        await expectError(.indexOutOfRange(what: "buffer", index: 3)) {
            try await importer.importAsset(at: url, options: options)
        }
    }

    @Test func rejectsBadIndexAccessors() async throws {
        // Index accessor with non-SCALAR type, then with float componentType.
        for (accessorJSON, expected) in [
            (
                #"{"bufferView": 1, "componentType": 5123, "count": 3, "type": "VEC3"}"#,
                GLTFImporter.GLTFError.unsupportedAccessor("index accessor 1: type VEC3")
            ),
            (
                #"{"bufferView": 1, "componentType": 5126, "count": 3, "type": "SCALAR"}"#,
                GLTFImporter.GLTFError.unsupportedAccessor("index accessor 1: componentType 5126")
            ),
        ] {
            let json = """
            {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
             "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
             "buffers": [{"byteLength": 42}],
             "bufferViews": [{"buffer": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
             "accessors": [
               {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
               \(accessorJSON)
             ]}
            """
            let glb = GLTFFixtures.glb(json: json, bin: GLTFFixtures.triangleBIN())
            let url = try GLTFFixtures.write(glb, name: "badidx.glb")
            await expectError(expected) { try await importer.importAsset(at: url, options: options) }
        }
    }

    @Test func dropsTexturesWithoutSourceOrImage() async throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "materials": [
            {"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}},
            {"pbrMetallicRoughness": {"baseColorTexture": {"index": 1}}}
          ],
          "textures": [{}, {"source": 9}]
        }
        """
        let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json), name: "nosource.glb")
        let result = try await importer.importAsset(at: url, options: options)
        #expect(result.scene.materials.allSatisfy { $0.baseColorTexture == nil })
        #expect(result.diagnostics.filter { $0.message.contains("unresolvable") }.count == 2)
    }

    @Test func readsUByteAndUIntIndices() async throws {
        for (componentType, indexBytes) in [
            (5121, Data([0, 1, 2])),
            (5125, GLTFFixtures.uint32LE(0) + GLTFFixtures.uint32LE(1) + GLTFFixtures.uint32LE(2)),
        ] {
            let json = """
            {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
             "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
             "buffers": [{"byteLength": \(36 + indexBytes.count)}],
             "bufferViews": [
               {"buffer": 0, "byteLength": 36},
               {"buffer": 0, "byteOffset": 36, "byteLength": \(indexBytes.count)}
             ],
             "accessors": [
               {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
               {"bufferView": 1, "componentType": \(componentType), "count": 3, "type": "SCALAR"}
             ]}
            """
            let bin = GLTFFixtures.floats(GLTFFixtures.trianglePositions) + indexBytes
            let url = try GLTFFixtures.write(GLTFFixtures.glb(json: json, bin: bin), name: "idx\(componentType).glb")
            let result = try await importer.importAsset(at: url, options: options)
            #expect(result.scene.meshes.first?.indices == [0, 1, 2])
        }
    }

    @Test func sceneNodesAreHashable() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)
        let a = SceneNode(name: "A", transform: transform)
        let set: Set<SceneNode> = [a, SceneNode(name: "A", transform: transform), SceneNode(name: "B")]
        #expect(set.count == 2)
    }

    @Test func supportedExtensionsAreDeclared() {
        #expect(GLTFImporter.supportedExtensions == ["glb", "gltf"])
    }

    @Test func decodeDataURIRejectsNonBase64Forms() {
        #expect(GLTFImporter.Builder.decodeDataURI("http://x") == nil)
        #expect(GLTFImporter.Builder.decodeDataURI("data:text/plain,hello") == nil)
        #expect(GLTFImporter.Builder.decodeDataURI("data:application/octet-stream;base64,AAEC") == Data([0, 1, 2]))
    }

    // MARK: Helpers

    private func expectError(
        _ expected: GLTFImporter.GLTFError,
        _ body: () async throws -> ImportResult
    ) async {
        do {
            _ = try await body()
            Issue.record("expected \(expected), got success")
        } catch let error as GLTFImporter.GLTFError {
            #expect(error == expected)
        } catch {
            Issue.record("expected GLTFError, got \(error)")
        }
    }
}
