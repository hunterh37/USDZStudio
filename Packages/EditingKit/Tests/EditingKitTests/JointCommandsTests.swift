import Testing
import USDCore
import MechanismKit
@testable import EditingKit

private func xform(_ path: String, translate t: [Double] = [0, 0, 0], children: [Prim] = []) -> Prim {
    let attr = Attribute(name: transformAttributeName,
                         value: .matrix4(TRS(translation: t).toMatrix()))
    return Prim(path: PrimPath(path)!, typeName: "Xform", attributes: [attr], children: children)
}

private func lidJoint(open: Double = 105) -> Joint {
    Joint.openable(name: "lidHinge", kind: .revolute, target: "Lid",
                   axis: [1, 0, 0], pivot: [0, 0.5, -0.5], openValue: open)
}

@Suite("CreateJointCommand")
struct CreateJointCommandTests {

    /// A case body with a lid at local translate (0, 1, 0), under an assembly root.
    private func stage() -> InMemoryStage {
        let lid = xform("/Case/Lid", translate: [0, 1, 0])
        let base = xform("/Case/Base")
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [base, lid])
        return InMemoryStage(StageSnapshot(rootPrims: [root]))
    }

    @Test func insertsPivotAndKeepsGeometryInPlaceThenUndoes() throws {
        let s = stage()
        let target = PrimPath("/Case/Lid")!
        let worldBefore = s.worldMatrix(at: target)

        let cmd = try #require(CreateJointCommand.make(target: target, joint: lidJoint(), in: s))
        #expect(cmd.pivotPath == PrimPath("/Case/Lid_pivot")!)
        #expect(cmd.movedPartPath == PrimPath("/Case/Lid_pivot/Lid")!)
        #expect(cmd.label == "Add Hinge to Lid")

        try cmd.execute(on: s)
        // The lid now lives under the pivot, and its closed-world placement is
        // unchanged (inserting the hinge must not move the part).
        #expect(s.prim(at: PrimPath("/Case/Lid")!) == nil)
        let worldAfter = s.worldMatrix(at: cmd.movedPartPath)
        for (a, b) in zip(worldBefore, worldAfter) { #expect(abs(a - b) < 1e-9) }

        // The pivot carries the joint description, decodable and consistent.
        let joint = try #require(SetJointStateCommand.jointOnPivot(cmd.pivotPath, in: s))
        #expect(joint.target == "Lid")
        #expect(joint.name == "lidHinge")

        try cmd.undo(on: s)
        #expect(s.prim(at: PrimPath("/Case/Lid")!) != nil)
        #expect(s.prim(at: cmd.pivotPath) == nil)
    }

    @Test func forcesJointTargetToMatchPrim() throws {
        let s = stage()
        var j = lidJoint(); j.target = "SomethingElse"
        let cmd = try #require(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: j, in: s))
        #expect(cmd.joint.target == "Lid")
    }

    @Test func prismaticLabel() throws {
        let s = stage()
        let drawer = Joint.openable(name: "slide", kind: .prismatic, target: "Lid",
                                    axis: [0, 0, 1], pivot: [0, 0, 0], openValue: 3)
        let cmd = try #require(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: drawer, in: s))
        #expect(cmd.label == "Add Slider to Lid")
    }

    @Test func rejectsRootTarget() {
        let s = stage()
        #expect(CreateJointCommand.make(target: .root, joint: lidJoint(), in: s) == nil)
    }

    @Test func rejectsMissingTarget() {
        let s = stage()
        #expect(CreateJointCommand.make(target: PrimPath("/Case/Nope")!, joint: lidJoint(), in: s) == nil)
    }

    @Test func rejectsInvalidJoint() {
        let s = stage()
        var bad = lidJoint(); bad.axis = [0, 0, 0]   // degenerate axis
        #expect(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: bad, in: s) == nil)
    }

    @Test func targetWithoutTransformDefaultsIdentity() throws {
        // A lid prim with no authored xformOp:transform → treated as identity.
        let lid = Prim(path: PrimPath("/Case/Lid")!, typeName: "Mesh")
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [lid])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))
        let cmd = try #require(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: lidJoint(), in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: cmd.movedPartPath) != nil)
    }
}

@Suite("SetJointStateCommand")
struct SetJointStateCommandTests {

    private func hingedStage() throws -> (InMemoryStage, PrimPath) {
        let lid = xform("/Case/Lid", translate: [0, 1, 0])
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [lid])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))
        let create = try #require(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: lidJoint(), in: s))
        try create.execute(on: s)
        return (s, create.pivotPath)
    }

    @Test func opensAndUndoesToClosed() throws {
        let (s, pivot) = try hingedStage()
        let closed = s.worldMatrix(at: PrimPath("/Case/Lid_pivot/Lid")!)

        let open = try #require(SetJointStateCommand.make(pivotPath: pivot, state: "open", in: s))
        #expect(open.label == "Set Lid_pivot → open")
        try open.execute(on: s)
        let opened = s.worldMatrix(at: PrimPath("/Case/Lid_pivot/Lid")!)
        // The lid actually moved when opened.
        #expect(zip(closed, opened).contains { abs($0 - $1) > 1e-3 })

        try open.undo(on: s)
        let reclosed = s.worldMatrix(at: PrimPath("/Case/Lid_pivot/Lid")!)
        for (a, b) in zip(closed, reclosed) { #expect(abs(a - b) < 1e-9) }
    }

    @Test func explicitValueWithinLimits() throws {
        let (s, pivot) = try hingedStage()
        let cmd = try #require(SetJointStateCommand.make(pivotPath: pivot, value: 42, in: s))
        #expect(cmd.label == "Set Lid_pivot → 42°")
        try cmd.execute(on: s)
    }

    @Test func decimalValueLabel() throws {
        let (s, pivot) = try hingedStage()
        let cmd = try #require(SetJointStateCommand.make(pivotPath: pivot, value: 42.5, in: s))
        #expect(cmd.label == "Set Lid_pivot → 42.5°")
    }

    @Test func prismaticValueLabelUsesUnits() throws {
        let lid = xform("/Case/Lid")
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [lid])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))
        let drawer = Joint.openable(name: "slide", kind: .prismatic, target: "Lid",
                                    axis: [0, 0, 1], pivot: [0, 0, 0], openValue: 5)
        let create = try #require(CreateJointCommand.make(target: PrimPath("/Case/Lid")!, joint: drawer, in: s))
        try create.execute(on: s)
        let cmd = try #require(SetJointStateCommand.make(pivotPath: create.pivotPath, value: 2, in: s))
        #expect(cmd.label == "Set Lid_pivot → 2u")
    }

    @Test func rejectsUnknownState() throws {
        let (s, pivot) = try hingedStage()
        #expect(SetJointStateCommand.make(pivotPath: pivot, state: "ajar", in: s) == nil)
    }

    @Test func rejectsOutOfLimitValue() throws {
        let (s, pivot) = try hingedStage()
        #expect(SetJointStateCommand.make(pivotPath: pivot, value: 999, in: s) == nil)
    }

    @Test func rejectsPivotWithoutJoint() {
        let plain = xform("/Case/Plain")
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [plain])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))
        #expect(SetJointStateCommand.make(pivotPath: PrimPath("/Case/Plain")!, state: "open", in: s) == nil)
        #expect(SetJointStateCommand.make(pivotPath: PrimPath("/Case/Plain")!, value: 1, in: s) == nil)
        #expect(SetJointStateCommand.jointOnPivot(PrimPath("/Case/Plain")!, in: s) == nil)
    }
}

@Suite("JointCoding & helpers")
struct JointCodingTests {
    @Test func encodeDecodeRoundTrips() {
        let j = lidJoint()
        let decoded = try? #require(JointCoding.decode(JointCoding.encode(j)))
        #expect(decoded == j)
    }

    @Test func decodeRejectsGarbage() {
        #expect(JointCoding.decode("not json") == nil)
    }

    @Test func localTransformFallsBackToIdentity() {
        // Prim with a malformed (wrong-length) matrix → identity fallback.
        let bad = Prim(path: PrimPath("/X")!, typeName: "Xform",
                       attributes: [Attribute(name: transformAttributeName, value: .matrix4([1, 2, 3]))])
        let s = InMemoryStage(StageSnapshot(rootPrims: [bad]))
        #expect(localTransformRowMajor(of: PrimPath("/X")!, in: s) == Matrix4.identity)
        #expect(localTransformRowMajor(of: PrimPath("/Missing")!, in: s) == Matrix4.identity)
    }
}
