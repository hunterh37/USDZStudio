import Testing
import Foundation
import simd
import USDCore
@testable import ConversionKit

@Suite("SanitizeNamesStage")
struct SanitizeNamesStageTests {

    private func run(_ scene: IntermediateScene) async throws -> ConversionContext {
        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/in.glb"), scene: scene)
        try await SanitizeNamesStage().process(&context)
        return context
    }

    @Test func sanitizerMatchesUSDIdentifierRules() {
        #expect(USDNameSanitizer.sanitize("Tri Node") == "Tri_Node")
        #expect(USDNameSanitizer.sanitize("2wheels") == "_2wheels")
        #expect(USDNameSanitizer.sanitize("") == "_")
        #expect(USDNameSanitizer.sanitize("ok_name9") == "ok_name9")
        #expect(USDNameSanitizer.isLegal("ok_name9"))
        #expect(!USDNameSanitizer.isLegal("Tri Node"))
        #expect(!USDNameSanitizer.isLegal(""))
    }

    @Test func renamesNodesMeshesAndMaterialsWithDiagnostics() async throws {
        let scene = IntermediateScene(
            rootNodes: [SceneNode(name: "Tri Node", children: [SceneNode(name: "leg-1")])],
            meshes: [MeshData(name: "my mesh")],
            materials: [PBRMaterial(name: "mat.metal")]
        )
        let context = try await run(scene)
        #expect(context.scene.rootNodes.first?.name == "Tri_Node")
        #expect(context.scene.rootNodes.first?.children.first?.name == "leg_1")
        #expect(context.scene.meshes.first?.name == "my_mesh")
        #expect(context.scene.materials.first?.name == "mat_metal")
        #expect(context.diagnostics.count == 4)
        #expect(context.diagnostics.allSatisfy { $0.severity == .info && $0.stage == "sanitize-names" })
        #expect(context.diagnostics.first?.message.contains("Tri Node") == true)
    }

    @Test func dedupesSiblingCollisions() async throws {
        let scene = IntermediateScene(rootNodes: [
            SceneNode(name: "part one"),
            SceneNode(name: "part_one"),
            SceneNode(name: "part.one"),
        ])
        let context = try await run(scene)
        #expect(context.scene.rootNodes.map(\.name) == ["part_one", "part_one_1", "part_one_2"])
        // Non-sibling duplicates are fine (different namespaces).
        let nested = try await run(IntermediateScene(rootNodes: [
            SceneNode(name: "a", children: [SceneNode(name: "x")]),
            SceneNode(name: "b", children: [SceneNode(name: "x")]),
        ]))
        #expect(nested.scene.allNodes().filter { $0.name == "x" }.count == 2)
        #expect(nested.diagnostics.isEmpty)
    }

    @Test func legalNamesPassUntouched() async throws {
        let scene = IntermediateScene(
            rootNodes: [SceneNode(name: "Clean")],
            meshes: [MeshData(name: "Mesh_0")],
            materials: [PBRMaterial(name: "Steel")]
        )
        let context = try await run(scene)
        #expect(context.scene == scene)
        #expect(context.diagnostics.isEmpty)
    }
}

@Suite("USDAuthorStage")
struct USDAuthorStageTests {

    private func author(_ scene: IntermediateScene, name: String = "asset") async throws -> StageSnapshot {
        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/in/\(name).glb"), scene: scene)
        try await USDAuthorStage().process(&context)
        return try #require(context.authoredStage)
    }

    @Test func authorsHierarchyMeshesAndMaterials() async throws {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)
        let scene = IntermediateScene(
            name: "Car",
            rootNodes: [SceneNode(
                name: "Body", transform: transform, meshIndices: [0],
                children: [SceneNode(name: "Wheel")])],
            meshes: [MeshData(
                name: "BodyMesh",
                positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
                indices: [0, 1, 2],
                materialIndex: 0)],
            materials: [PBRMaterial(name: "Paint", baseColorFactor: SIMD4(1, 0, 0, 1), doubleSided: true)]
        )
        let stage = try await author(scene)

        #expect(stage.metadata.defaultPrim == "Car")
        #expect(stage.metadata.upAxis == .y)
        #expect(stage.metadata.metersPerUnit == 1.0)

        let body = try #require(stage.prim(at: PrimPath("/Car/Body")!))
        #expect(body.typeName == "Xform")
        // Row-major matrix: translation lands in the last column of each row.
        #expect(body.attribute(named: "xformOp:transform")?.value ==
            .matrix4([1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1]))

        let mesh = try #require(stage.prim(at: PrimPath("/Car/Body/BodyMesh")!))
        #expect(mesh.typeName == "Mesh")
        // Positions/normals are authored as canonical `point3f[]`/`normal3f[]`
        // (`.float3Array`), the type every geometry reader and RealityKit expect.
        // UVs stay `.doubleArray` (arity-2; the serializer maps them to
        // `texCoord2f[]`).
        #expect(mesh.attribute(named: "points")?.value == .float3Array([0, 0, 0, 1, 0, 0, 0, 1, 0]))
        #expect(mesh.attribute(named: "faceVertexIndices")?.value == .intArray([0, 1, 2]))
        #expect(mesh.attribute(named: "faceVertexCounts")?.value == .intArray([3]))
        #expect(mesh.attribute(named: "normals")?.value == .float3Array([0, 0, 1, 0, 0, 1, 0, 0, 1]))
        #expect(mesh.attribute(named: "primvars:st")?.value == .doubleArray([0, 0, 1, 0, 0, 1]))
        #expect(mesh.metadata["material:binding"] == "Paint")

        #expect(stage.prim(at: PrimPath("/Car/Body/Wheel")!) != nil)

        let material = try #require(stage.prim(at: PrimPath("/Car/Materials/Paint")!))
        #expect(material.typeName == "Material")
        #expect(material.attribute(named: "inputs:diffuseColor")?.value == .vector([1, 0, 0]))
        #expect(material.attribute(named: "inputs:metallic")?.value == .double(1))
        #expect(material.attribute(named: "inputs:roughness")?.value == .double(1))
        #expect(material.attribute(named: "doubleSided")?.value == .bool(true))
        #expect(material.attribute(named: "inputs:opacity") == nil)
    }

    /// A source mesh with geometry but no normals gets smooth per-vertex
    /// normals derived from its topology (issue #95), so the authored stage
    /// never emits a mesh that trips the `mesh.normals` diagnostic.
    @Test func derivesNormalsWhenSourceHasNone() async throws {
        let scene = IntermediateScene(
            name: "Tri",
            rootNodes: [SceneNode(name: "N", meshIndices: [0])],
            meshes: [MeshData(
                name: "M",
                positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                normals: [], // source omits normals
                indices: [0, 1, 2])])
        let stage = try await author(scene)
        let mesh = try #require(stage.prim(at: PrimPath("/Tri/N/M")!))
        // A CCW triangle in the z=0 plane → unit +Z normal at every vertex.
        #expect(mesh.attribute(named: "normals")?.value == .float3Array([0, 0, 1, 0, 0, 1, 0, 0, 1]))
    }

    /// Degenerate topology (indices out of range) can't yield honest normals,
    /// so none are authored rather than fabricating a direction.
    @Test func authorsNoNormalsForUnderivableTopology() async throws {
        let scene = IntermediateScene(
            name: "Bad",
            rootNodes: [SceneNode(name: "N", meshIndices: [0])],
            meshes: [MeshData(
                name: "M",
                positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                normals: [],
                indices: [0, 1, 9])]) // index 9 is out of range
        let stage = try await author(scene)
        let mesh = try #require(stage.prim(at: PrimPath("/Bad/N/M")!))
        #expect(mesh.attribute(named: "normals") == nil)
    }

    @Test func authorsAlphaModes() async throws {
        let scene = IntermediateScene(name: "A", materials: [
            PBRMaterial(name: "Masked", baseColorFactor: SIMD4(1, 1, 1, 0.5), alphaMode: .mask(threshold: 0.25)),
            PBRMaterial(name: "Blended", baseColorFactor: SIMD4(1, 1, 1, 0.75), alphaMode: .blend),
        ])
        let stage = try await author(scene)
        let masked = try #require(stage.prim(at: PrimPath("/A/Materials/Masked")!))
        #expect(masked.attribute(named: "inputs:opacityThreshold")?.value == .double(0.25))
        #expect(masked.attribute(named: "inputs:opacity")?.value == .double(0.5))
        let blended = try #require(stage.prim(at: PrimPath("/A/Materials/Blended")!))
        #expect(blended.attribute(named: "inputs:opacity")?.value == .double(0.75))
        #expect(blended.attribute(named: "inputs:opacityThreshold") == nil)
    }

    @Test func illegalSceneNameFallsBackToRoot() async throws {
        let stage = try await author(IntermediateScene(name: "my scene!"))
        #expect(stage.metadata.defaultPrim == "Root")
        #expect(stage.rootPrims.first?.name == "Root")
    }

    @Test func dedupesMeshChildNamesAndThrowsOnBadInput() async throws {
        // Two identical mesh names under one node get deduped.
        let scene = IntermediateScene(
            name: "S",
            rootNodes: [SceneNode(name: "N", meshIndices: [0, 1])],
            meshes: [MeshData(name: "M"), MeshData(name: "M")]
        )
        let stage = try await author(scene)
        let node = try #require(stage.prim(at: PrimPath("/S/N")!))
        #expect(node.children.map(\.name) == ["M", "M_1"])

        // Unsanitized node name → error (sanitize-names must run first).
        await #expect(throws: USDAuthorStage.AuthorError.illegalName("bad name")) {
            _ = try await author(IntermediateScene(name: "S", rootNodes: [SceneNode(name: "bad name")]))
        }
        // Dangling mesh index → error.
        await #expect(throws: USDAuthorStage.AuthorError.danglingMeshIndex(node: "N", index: 3)) {
            _ = try await author(IntermediateScene(name: "S", rootNodes: [SceneNode(name: "N", meshIndices: [3])]))
        }
        // Unsanitized material name → error.
        await #expect(throws: USDAuthorStage.AuthorError.illegalName("bad mat")) {
            _ = try await author(IntermediateScene(name: "S", materials: [PBRMaterial(name: "bad mat")]))
        }
    }

    @Test func meshWithUnboundMaterialIndexHasNoBinding() async throws {
        let scene = IntermediateScene(
            name: "S",
            rootNodes: [SceneNode(name: "N", meshIndices: [0])],
            meshes: [MeshData(name: "M", positions: [SIMD3(0, 0, 0)], indices: [0, 0, 0], materialIndex: 9)]
        )
        let stage = try await author(scene)
        let mesh = try #require(stage.prim(at: PrimPath("/S/N/M")!))
        #expect(mesh.metadata["material:binding"] == nil)
        #expect(mesh.attribute(named: "normals") == nil)
        #expect(mesh.attribute(named: "primvars:st") == nil)
    }
}

@Suite("End-to-end: GLB → pipeline → StageSnapshot")
struct GLBEndToEndTests {

    @Test func convertsTriangleGLBToAuthoredStage() async throws {
        let glb = GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN())
        let url = try GLTFFixtures.write(glb, name: "triangle.glb")

        let imported = try await GLTFImporter().importAsset(at: url, options: ImportOptions())
        var context = ConversionContext(
            sourceURL: url, scene: imported.scene, diagnostics: imported.diagnostics)
        context = try await ConversionPipeline(stages: [
            SanitizeNamesStage(),
            USDAuthorStage(),
        ]).run(context)

        #expect(context.log == ["sanitize-names: ok (1 diagnostic)", "usd-author: ok"])
        let stage = try #require(context.authoredStage)
        #expect(stage.metadata.defaultPrim == "triangle")
        let mesh = try #require(stage.prim(at: PrimPath("/triangle/Tri_Node/Tri")!))
        #expect(mesh.typeName == "Mesh")
        #expect(mesh.metadata["material:binding"] == "Red")
        #expect(stage.prim(at: PrimPath("/triangle/Materials/Red")!) != nil)
    }
}
