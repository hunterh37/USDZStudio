import Testing
import USDCore
import MechanismKit
@testable import EditingKit

/// A `/Case` assembly whose `Lid` has been given a hinge, driven to `value`.
/// Mirrors what `CreateJointCommand` + `SetJointStateCommand` produce on disk.
private func hingedStage(open: Double = 105, at value: Double = 0) -> InMemoryStage {
    let joint = Joint.openable(name: "lidHinge", kind: .revolute, target: "Lid",
                               axis: [1, 0, 0], pivot: [0, 0.5, -0.5], openValue: open)
    let lid = Prim(path: PrimPath("/Case/Lid_pivot/Lid")!, typeName: "Xform")
    let pivot = Prim(
        path: PrimPath("/Case/Lid_pivot")!, typeName: "Xform",
        attributes: [
            Attribute(name: transformAttributeName,
                      value: .matrix4(PivotMath.pivotTransformRowMajor(joint, value: value))),
            Attribute(name: jointAttributeName,
                      value: .string(JointCoding.encode(joint)), isUniform: true),
        ],
        children: [lid])
    let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [pivot])
    return InMemoryStage(StageSnapshot(rootPrims: [root]))
}

@Suite("JointDiscovery")
struct JointDiscoveryTests {

    @Test func emptyStageHasNoJoints() {
        let s = InMemoryStage(StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/Cube")!, typeName: "Mesh")]))
        #expect(JointDiscovery.joints(in: s).isEmpty)
    }

    @Test func discoversHingeInClosedState() throws {
        let found = JointDiscovery.joints(in: hingedStage(at: 0))
        let j = try #require(found.first)
        #expect(found.count == 1)
        #expect(j.pivotPath == PrimPath("/Case/Lid_pivot")!)
        #expect(j.id == "/Case/Lid_pivot")
        #expect(j.name == "lidHinge")
        #expect(j.isRevolute)
        #expect(j.kindLabel == "Hinge")
        #expect(j.unitSuffix == "°")
        #expect(j.stateNames == ["closed", "open"])
        #expect(j.activeState == "closed")
        #expect(abs(j.currentValue) < 1e-6)
        #expect(j.minValue == 0)
        #expect(j.maxValue == 105)
        #expect(j.value(ofState: "open") == 105)
        #expect(j.value(ofState: "nope") == nil)
    }

    @Test func recognizesOpenStateFromLivePose() throws {
        let j = try #require(JointDiscovery.joints(in: hingedStage(at: 105)).first)
        #expect(j.activeState == "open")
        #expect(abs(j.currentValue - 105) < 1e-6)
    }

    @Test func inBetweenPoseHasNoActiveStateButKeepsValue() throws {
        let j = try #require(JointDiscovery.joints(in: hingedStage(at: 52)).first)
        #expect(j.activeState == nil)
        #expect(abs(j.currentValue - 52) < 1e-6)
    }

    @Test func sliderProjectsKindLabelAndUnit() throws {
        let joint = Joint.openable(name: "slide", kind: .prismatic, target: "Drawer",
                                   axis: [0, 0, 1], pivot: [0, 0, 0], openValue: 4)
        let drawer = Prim(path: PrimPath("/Cab/Drawer_pivot/Drawer")!, typeName: "Xform")
        let pivot = Prim(
            path: PrimPath("/Cab/Drawer_pivot")!, typeName: "Xform",
            attributes: [
                Attribute(name: transformAttributeName,
                          value: .matrix4(PivotMath.pivotTransformRowMajor(joint, value: 4))),
                Attribute(name: jointAttributeName,
                          value: .string(JointCoding.encode(joint)), isUniform: true),
            ], children: [drawer])
        let root = Prim(path: PrimPath("/Cab")!, typeName: "Xform", children: [pivot])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))

        let j = try #require(JointDiscovery.joints(in: s).first)
        #expect(!j.isRevolute)
        #expect(j.kindLabel == "Slider")
        #expect(j.unitSuffix == "u")
        #expect(j.activeState == "open")
    }

    @Test func skipsMalformedJointAttribute() {
        let pivot = Prim(path: PrimPath("/Bad_pivot")!, typeName: "Xform",
                         attributes: [Attribute(name: jointAttributeName,
                                                value: .string("{not json"), isUniform: true)])
        let s = InMemoryStage(StageSnapshot(rootPrims: [pivot]))
        #expect(JointDiscovery.joints(in: s).isEmpty)
    }

    @Test func skipsNonStringJointAttribute() {
        // Defensive: a same-named attribute of the wrong value type is not a joint.
        let pivot = Prim(path: PrimPath("/Odd_pivot")!, typeName: "Xform",
                         attributes: [Attribute(name: jointAttributeName, value: .double(3))])
        let s = InMemoryStage(StageSnapshot(rootPrims: [pivot]))
        #expect(JointDiscovery.joints(in: s).isEmpty)
    }

    @Test func pivotWithoutTransformFallsBackToClosed() throws {
        // A pivot that authors the joint but no xformOp:transform reads as rest (0).
        let joint = Joint.openable(name: "lidHinge", kind: .revolute, target: "Lid",
                                   axis: [1, 0, 0], pivot: [0, 0.5, -0.5], openValue: 90)
        let pivot = Prim(path: PrimPath("/Case/Lid_pivot")!, typeName: "Xform",
                         attributes: [Attribute(name: jointAttributeName,
                                                value: .string(JointCoding.encode(joint)), isUniform: true)])
        let root = Prim(path: PrimPath("/Case")!, typeName: "Xform", children: [pivot])
        let s = InMemoryStage(StageSnapshot(rootPrims: [root]))
        let j = try #require(JointDiscovery.joints(in: s).first)
        #expect(j.activeState == "closed")
        #expect(abs(j.currentValue) < 1e-6)
    }

    @Test func jointsReturnedInStablePathOrder() {
        // Two hinges authored under sibling roots, deliberately out of path order,
        // come back sorted by path so the panel list is deterministic.
        func hinge(_ root: String) -> Prim {
            let joint = Joint.openable(name: "\(root)Hinge", kind: .revolute, target: "Lid",
                                       axis: [1, 0, 0], pivot: [0, 0, 0], openValue: 90)
            let pivot = Prim(path: PrimPath("/\(root)/Lid_pivot")!, typeName: "Xform",
                             attributes: [Attribute(name: jointAttributeName,
                                                    value: .string(JointCoding.encode(joint)), isUniform: true)])
            return Prim(path: PrimPath("/\(root)")!, typeName: "Xform", children: [pivot])
        }
        let s = InMemoryStage(StageSnapshot(rootPrims: [hinge("Zeta"), hinge("Alpha")]))
        #expect(JointDiscovery.joints(in: s).map(\.pivotPath.description)
                == ["/Alpha/Lid_pivot", "/Zeta/Lid_pivot"])
    }
}
