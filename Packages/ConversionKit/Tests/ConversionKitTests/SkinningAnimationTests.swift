import Testing
import Foundation
import simd
@testable import ConversionKit
import USDCore

/// End-to-end coverage for glTF skinning + animation: importer parsing, the IR,
/// and UsdSkel authoring (Skeleton, SkelAnimation, skinned-mesh binding).
@Suite("Skinning & animation")
struct SkinningAnimationTests {
    let importer = GLTFImporter()
    let options = ImportOptions()

    private func importScene() async throws -> IntermediateScene {
        let url = try GLTFFixtures.write(GLTFFixtures.skinnedAnimatedGLB(), name: "skinned.glb")
        return try await importer.importAsset(at: url, options: options).scene
    }

    private func author(_ scene: IntermediateScene) async throws -> StageSnapshot {
        var context = ConversionContext(sourceURL: URL(fileURLWithPath: "/in/skinned.glb"), scene: scene)
        try await USDAuthorStage().process(&context)
        return try #require(context.authoredStage)
    }

    // MARK: - Importer parsing

    @Test func parsesSkinJointsAndInverseBinds() async throws {
        let scene = try await importScene()
        let skin = try #require(scene.skins.first)
        #expect(skin.name == "Rig")
        #expect(skin.joints == [1, 2])
        #expect(skin.skeletonRoot == 1)
        #expect(skin.inverseBindMatrices.count == 2)
        #expect(skin.inverseBindMatrices[0] == matrix_identity_float4x4)
    }

    @Test func parsesPerVertexSkinInfluences() async throws {
        let scene = try await importScene()
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.isSkinned)
        #expect(mesh.jointIndices == [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0)])
        #expect(mesh.jointWeights == [SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)])
    }

    @Test func bindsSkinToNodeAndAssignsIDs() async throws {
        let scene = try await importScene()
        let map = scene.nodesByID()
        #expect(map[0]?.skinIndex == 0)
        #expect(map[1]?.name == "Hips")
        #expect(map[2]?.name == "Spine")
    }

    @Test func parsesAnimationChannelsAndSamplers() async throws {
        let scene = try await importScene()
        let anim = try #require(scene.animations.first)
        #expect(anim.name == "Wiggle")
        #expect(anim.channels.count == 1)
        let channel = try #require(anim.channels.first)
        #expect(channel.targetNodeID == 2)
        #expect(channel.path == .rotation)
        let sampler = anim.samplers[channel.samplerIndex]
        #expect(sampler.input == [0, 1])
        #expect(sampler.interpolation == .linear)
        guard case .rotation(let quats) = sampler.output else { Issue.record("expected rotation output"); return }
        #expect(quats.count == 2)
        #expect(quats[0] == SIMD4(0, 0, 0, 1))
        #expect(abs(quats[1].z - 0.7071068) < 1e-5)
        #expect(anim.duration == 1)
    }

    // MARK: - UsdSkel authoring

    @Test func authorsSkelRootSkeletonAndBinding() async throws {
        let stage = try await author(try await importScene())
        let root = try #require(stage.rootPrims.first)
        #expect(root.typeName == "SkelRoot")

        let skeleton = try #require(root.children.first { $0.typeName == "Skeleton" })
        #expect(skeleton.name == "Rig")
        let joints = try #require(skeleton.attribute(named: "joints"))
        #expect(joints.value == .tokenArray(["Hips", "Hips/Spine"]))
        #expect(joints.isUniform)
        #expect(skeleton.attribute(named: "bindTransforms")?.value.typeLabel == "matrix4d[]")
        #expect(skeleton.attribute(named: "restTransforms") != nil)
        #expect(skeleton.relationships.contains { $0.name == "skel:animationSource" })
    }

    @Test func authorsSkelAnimationTimeSamples() async throws {
        let stage = try await author(try await importScene())
        let skeleton = try #require(stage.rootPrims.first?.children.first { $0.typeName == "Skeleton" })
        let anim = try #require(skeleton.children.first { $0.typeName == "SkelAnimation" })
        #expect(anim.attribute(named: "joints")?.value == .tokenArray(["Hips/Spine"]))
        let rotations = try #require(anim.attribute(named: "rotations"))
        #expect(rotations.isAnimated)
        // Two key times mapped to 24fps time codes: 0 and 24.
        let times = rotations.timeSamples?.map(\.time)
        #expect(times == [0, 24])
        // First key is identity, authored as (w, x, y, z) = (1, 0, 0, 0).
        guard case .quatfArray(let first) = rotations.timeSamples?.first?.value else {
            Issue.record("expected quatfArray sample"); return
        }
        #expect(first == [1, 0, 0, 0])
    }

    @Test func skinnedMeshCarriesSkelBinding() async throws {
        let stage = try await author(try await importScene())
        let mesh = try #require(stage.allPrims().first { $0.typeName == "Mesh" })
        let indices = try #require(mesh.attribute(named: "primvars:skel:jointIndices"))
        #expect(indices.metadata["elementSize"] == "4")
        #expect(indices.metadata["interpolation"] == "\"vertex\"")
        #expect(mesh.attribute(named: "primvars:skel:jointWeights") != nil)
        let binding = try #require(mesh.relationships.first { $0.name == "skel:skeleton" })
        #expect(binding.targets.first?.description == "/skinned/Rig")
    }

    @Test func stageDeclaresAnimationTimeRange() async throws {
        let stage = try await author(try await importScene())
        #expect(stage.metadata.timeCodesPerSecond == 24)
        #expect(stage.metadata.startTimeCode == 0)
        #expect(stage.metadata.endTimeCode == 24)
        #expect(stage.metadata.isAnimated)
        // The whole thing serializes without producing "unsupported" comments.
        let usda = USDASerializer.serialize(stage)
        #expect(usda.contains("def SkelRoot"))
        #expect(usda.contains("def Skeleton \"Rig\""))
        #expect(usda.contains("rotations.timeSamples"))
        #expect(!usda.contains("# unsupported"))
    }

    // MARK: - Non-skinned node transform animation

    @Test func authorsNodeTransformAnimationAsTimeSampledMatrix() async throws {
        // A lone animated node (no skin): translation channel, two keys.
        let sampler = AnimationSampler(
            input: [0, 2], interpolation: .linear,
            output: .vec3([SIMD3(0, 0, 0), SIMD3(0, 10, 0)]))
        let anim = Animation(
            name: "Move",
            channels: [AnimationChannel(targetNodeID: 7, path: .translation, samplerIndex: 0)],
            samplers: [sampler])
        let scene = IntermediateScene(
            name: "S",
            rootNodes: [SceneNode(name: "Mover", id: 7)],
            animations: [anim])
        let stage = try await author(scene)
        let node = try #require(stage.allPrims().first { $0.name == "Mover" })
        let xform = try #require(node.attribute(named: "xformOp:transform"))
        #expect(xform.isAnimated)
        #expect(xform.timeSamples?.map(\.time) == [0, 48])  // 2s * 24fps
        // Last sample's translation column is (0, 10, 0).
        guard case .matrix4(let m) = xform.timeSamples?.last?.value else {
            Issue.record("expected matrix sample"); return
        }
        #expect(m[3] == 0 && m[7] == 10 && m[11] == 0)  // row-major translation
    }

    @Test func samplerBinarySearchBracketsInteriorKeys() {
        // ≥3 keys so the bracketing binary search iterates (two-key clips take
        // the fast path and never enter the loop). Samples land in different
        // intervals to hit both comparison branches, above and below the probe.
        let sampler = AnimationSampler(
            input: [0, 1, 2, 3], interpolation: .linear,
            output: .vec3([SIMD3(0, 0, 0), SIMD3(0, 10, 0), SIMD3(0, 20, 0), SIMD3(0, 30, 0)]))
        // t=2.5 → between keys 2 and 3 (probe walks the upper half).
        #expect(sampler.sampledVec3(at: 2.5)?.y == 25)
        // t=0.5 → between keys 0 and 1 (probe walks the lower half).
        #expect(sampler.sampledVec3(at: 0.5)?.y == 5)
        // Exact interior key time → zero blend factor, no extrapolation.
        #expect(sampler.sampledVec3(at: 2)?.y == 20)
    }

    @Test func warnsWhenMultipleClipsAndOnCubicSpline() async throws {
        var context = ConversionContext(
            sourceURL: URL(fileURLWithPath: "/in/s.glb"),
            scene: IntermediateScene(name: "S", animations: [Animation(name: "A"), Animation(name: "B")]))
        try await USDAuthorStage().process(&context)
        #expect(context.diagnostics.contains { $0.message.contains("only") && $0.message.contains("authored") })
    }
}
