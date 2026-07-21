import Testing
import USDCore
import RigKit
@testable import EditingKit

@Suite struct SkelCommandsTests {
    let animPath = PrimPath("/Anim")!

    func stage(_ prim: Prim) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: [prim]))
    }

    func pose() -> Pose {
        Pose(locals: [
            RigTransform(translation: Vec3(1, 2, 3)),
            RigTransform(translation: Vec3(4, 5, 6), rotation: Quat(axis: Vec3(0, 0, 1), degrees: 90), scale: Vec3(2, 2, 2)),
        ])
    }

    @Test func authorPoseWritesChannelsAndUndoesToAbsent() throws {
        let prim = Prim(path: animPath, typeName: "SkelAnimation")
        let s = stage(prim)
        let cmd = AuthorSkelPoseCommand(path: animPath, pose: pose(), existing: s.prim(at: animPath))
        #expect(cmd.label == "Pose Anim")
        try cmd.execute(on: s)
        #expect(s.prim(at: animPath)?.attribute(named: "translations")?.value == .float3Array([1, 2, 3, 4, 5, 6]))
        #expect(s.prim(at: animPath)?.attribute(named: "rotations")?.value == .quatfArray([1, 0, 0, 0, cos(45 * .pi / 180), 0, 0, sin(45 * .pi / 180)]))
        try cmd.undo(on: s)
        #expect(s.prim(at: animPath)?.attribute(named: "translations") == nil)   // removed (was absent)
    }

    @Test func authorPoseUndoRestoresPrevious() throws {
        let previous = Attribute(name: "translations", value: .float3Array([9, 9, 9, 9, 9, 9]))
        let prim = Prim(path: animPath, typeName: "SkelAnimation", attributes: [previous])
        let s = stage(prim)
        let cmd = AuthorSkelPoseCommand(path: animPath, pose: pose(), existing: s.prim(at: animPath))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.prim(at: animPath)?.attribute(named: "translations")?.value == .float3Array([9, 9, 9, 9, 9, 9]))
    }

    @Test func keyframeInsertsAndReplacesSorted() throws {
        let prim = Prim(path: animPath, typeName: "SkelAnimation")
        let s = stage(prim)
        // First key at t=10 (integer label).
        let k10 = SetSkelKeyframeCommand(path: animPath, timeCode: 10, pose: pose(), existing: s.prim(at: animPath))
        #expect(k10.label == "Key Anim @ 10")
        try k10.execute(on: s)
        // Second key at t=0.25 (fractional label) — different time → two samples.
        let k0 = SetSkelKeyframeCommand(path: animPath, timeCode: 0.25, pose: pose(), existing: s.prim(at: animPath))
        #expect(k0.label == "Key Anim @ 0.25")
        try k0.execute(on: s)
        let samples = try #require(s.prim(at: animPath)?.attribute(named: "translations")?.timeSamples)
        #expect(samples.map(\.time) == [0.25, 10])   // sorted
        #expect(s.prim(at: animPath)?.attribute(named: "translations")?.isAnimated == true)

        // Re-key at t=10 replaces rather than appends.
        let replace = SetSkelKeyframeCommand(path: animPath, timeCode: 10, pose: pose(), existing: s.prim(at: animPath))
        try replace.execute(on: s)
        #expect(s.prim(at: animPath)?.attribute(named: "translations")?.timeSamples?.count == 2)
        try replace.undo(on: s)
        #expect(s.prim(at: animPath)?.attribute(named: "translations")?.timeSamples?.count == 2)
    }

    @Test func authorSkinWritesPrimvarsWithElementSize() throws {
        let mesh = PrimPath("/Mesh")!
        let s = stage(Prim(path: mesh, typeName: "Mesh"))
        let cmd = AuthorSkinCommand(path: mesh, indices: [0, 1, 0, 2], weights: [0.7, 0.3, 0.6, 0.4],
                                    influencesPerVertex: 2, existing: s.prim(at: mesh))
        #expect(cmd.label == "Skin Mesh")
        try cmd.execute(on: s)
        let indices = s.prim(at: mesh)?.attribute(named: "primvars:skel:jointIndices")
        #expect(indices?.value == .intArray([0, 1, 0, 2]))
        #expect(indices?.metadata["elementSize"] == "2")
        try cmd.undo(on: s)
        #expect(s.prim(at: mesh)?.attribute(named: "primvars:skel:jointWeights") == nil)
    }

    @Test func clipRangeSetsAndUndoesMetadata() throws {
        let s = stage(Prim(path: animPath, typeName: "SkelAnimation"))
        // Reversed inputs are normalized (min/max).
        let cmd = SetClipRangeCommand(name: "walk", startTimeCode: 24, endTimeCode: 0, current: StageMetadata())
        #expect(cmd.label == "Clip walk")
        try cmd.execute(on: s)
        #expect(s.metadata.startTimeCode == 0)
        #expect(s.metadata.endTimeCode == 24)
        try cmd.undo(on: s)
        #expect(s.metadata.startTimeCode == nil)
    }
}

import func Foundation.cos
import func Foundation.sin
