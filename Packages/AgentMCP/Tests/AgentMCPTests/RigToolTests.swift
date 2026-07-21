import Foundation
import Testing
import USDCore
@testable import AgentMCP

/// Fixtures + helpers for the `.rig` tool group.
enum RigFixtures {
    /// Row-major translation matrix (16 doubles).
    static func translate(_ x: Double, _ y: Double, _ z: Double) -> [Double] {
        [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1]
    }

    /// A clean 3-joint humanoid-named chain skeleton prim at `/Rig`.
    static func rigPrim(path: String = "/Rig",
                        joints: [String] = ["Hips", "Hips/Spine", "Hips/Spine/Chest"]) -> Prim {
        let rest = translate(0, 0, 0) + translate(0, 1, 0) + translate(0, 1, 0)
        return Prim(path: PrimPath(path)!, typeName: "Skeleton", attributes: [
            Attribute(name: "joints", value: .tokenArray(joints)),
            Attribute(name: "restTransforms", value: .matrix4dArray(rest)),
        ])
    }

    /// A session containing `/Root` (with a `points` mesh at `/Root/Box`) and a `/Rig` skeleton.
    static func session() -> EditSession {
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims.append(rigPrim())
        return EditSession(snapshot: snapshot, strictness: .warn)
    }

    static func server(_ session: EditSession) -> MCPServer {
        AgentMCPServer.make(session: session, configuration: .init(workDirectory: Fixtures.tempDirectory()))
    }
}

@Suite("`.rig` introspection")
struct RigIntrospectionTests {
    @Test func listJointsReturnsHierarchy() async {
        let server = RigFixtures.server(RigFixtures.session())
        let r = await callOK(server, "list_joints", ["prim": "/Rig"])
        #expect(r["jointCount"].intValue == 3)
        let joints = r["joints"].arrayValue!
        #expect(joints[0]["path"].stringValue == "Hips")
        #expect(joints[0]["parent"].isNull)
        #expect(joints[1]["parent"].intValue == 0)
        #expect(joints[0]["childCount"].intValue == 1)
    }

    @Test func listJointsWithoutTargetErrors() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callError(server, "list_joints", [:])   // no prim, no active rig yet
    }

    @Test func listJointsRejectsNonSkeleton() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callError(server, "list_joints", ["prim": "/Root/Box"])   // has no 'joints'
    }

    @Test func identifyMapsCanonicalBonesAndSetsActive() async {
        let server = RigFixtures.server(RigFixtures.session())
        let r = await callOK(server, "identify_skeleton", ["prim": "/Rig"])
        #expect(r["matches"]["Hips"]["jointPath"].stringValue == "Hips")
        #expect(r["matches"]["Chest"]["jointPath"].stringValue == "Hips/Spine/Chest")
        #expect((r["matches"]["Hips"]["confidence"].doubleValue ?? 0) > 0.9)
        // Active rig now set → list_joints works without an explicit prim.
        let listed = await callOK(server, "list_joints", [:])
        #expect(listed["jointCount"].intValue == 3)
    }

    @Test func rigStatusReflectsState() async {
        let session = RigFixtures.session()
        let server = RigFixtures.server(session)
        _ = await callOK(server, "identify_skeleton", ["prim": "/Rig"])
        let status = await callOK(server, "rig_status", [:])
        #expect(status["canonicalMapBound"].boolValue == true)
        #expect(status["activeRig"].stringValue == "/Rig")
        #expect((status["motionQualityFloor"].doubleValue ?? 0) > 0)
    }

    @Test func rejectsInvalidRestTransforms() async {
        let session = RigFixtures.session()
        // A skeleton prim missing restTransforms.
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims.append(Prim(path: PrimPath("/Bad")!, typeName: "Skeleton",
            attributes: [Attribute(name: "joints", value: .tokenArray(["A"]))]))
        let s = EditSession(snapshot: snapshot, strictness: .warn)
        _ = session
        let server = RigFixtures.server(s)
        _ = await callError(server, "list_joints", ["prim": "/Bad"])
    }
}

@Suite("`.rig` authoring")
struct RigAuthoringTests {
    @Test func setJointPoseAuthorsChannels() async {
        let server = RigFixtures.server(RigFixtures.session())
        let r = await callOK(server, "set_joint_pose",
                             ["prim": "/Rig", "joint": "Hips/Spine", "translation": [0, 2, 0],
                              "rotation": [0.92388, 0, 0, 0.38268], "scale": [2, 2, 2]])
        #expect(r["joint"].intValue == 1)
        #expect(r["undoToken"].intValue != nil)
        // A second author reads the now-present default-time channels (currentPose full path).
        let second = await callOK(server, "set_joint_pose", ["prim": "/Rig", "joint": "Hips", "translation": [1, 0, 0]])
        #expect(second["joint"].intValue == 0)
    }

    @Test func setJointPoseRejectsUnknownJoint() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callError(server, "set_joint_pose", ["prim": "/Rig", "joint": "Nope"])
    }

    @Test func solveIKConvergesAndAuthors() async {
        let server = RigFixtures.server(RigFixtures.session())
        let r = await callOK(server, "solve_ik",
                             ["prim": "/Rig", "chain": ["Hips", "Hips/Spine", "Hips/Spine/Chest"],
                              "target": [0.5, 1.0, 0], "solver": "twoBone"])
        #expect(r["converged"].boolValue == true)
        #expect(r["iterations"].intValue == 0)   // analytic
    }

    @Test func solveIKByJointIndexAndPole() async {
        let server = RigFixtures.server(RigFixtures.session())
        let r = await callOK(server, "solve_ik",
                             ["prim": "/Rig", "chain": [0, 1, 2],
                              "target": [0.5, 1.0, 0.2], "poleVector": [1, 0.5, 0], "solver": "ccd"])
        #expect(r["residual"].doubleValue != nil)
    }

    @Test func solveIKRejectsBadArgs() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callError(server, "solve_ik", ["prim": "/Rig", "chain": ["Hips"], "target": [1, 0, 0]])
        _ = await callError(server, "solve_ik", ["prim": "/Rig", "chain": ["Hips", "Nope"], "target": [1, 0, 0]])
        _ = await callError(server, "solve_ik", ["prim": "/Rig", "chain": ["Hips", "Hips/Spine"]])
    }

    @Test func keyframeAndClip() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callOK(server, "set_keyframe", ["prim": "/Rig", "timeCode": 0])
        _ = await callOK(server, "set_keyframe",
                         ["prim": "/Rig", "timeCode": 1, "joint": "Hips/Spine",
                          "translation": [0, 1.5, 0], "rotation": [0.92388, 0, 0, 0.38268], "scale": [1, 1, 1]])
        _ = await callError(server, "set_keyframe", ["prim": "/Rig"])   // missing timeCode
        let clip = await callOK(server, "create_clip",
                                ["name": "walk", "startTimeCode": 0, "endTimeCode": 24])
        #expect(clip["clip"].stringValue == "walk")
        _ = await callError(server, "create_clip", ["name": "x"])
    }

    @Test func solveWeightsBindsMesh() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callOK(server, "identify_skeleton", ["prim": "/Rig"])   // set active rig
        let r = await callOK(server, "solve_weights", ["mesh": "/Root/Box", "maxInfluences": 2])
        #expect((r["vertexCount"].intValue ?? 0) > 0)
        #expect(r["maxInfluences"].intValue == 2)
        _ = await callError(server, "solve_weights", ["mesh": "/Root"])   // /Root has no points
    }

    @Test func autoRigProposesSkeleton() async {
        let server = RigFixtures.server(RigFixtures.session())
        let humanoid = await callOK(server, "auto_rig", ["mesh": "/Root/Box", "kind": "humanoid"])
        #expect((humanoid["jointCount"].intValue ?? 0) > 10)
        let generic = await callOK(server, "auto_rig", ["mesh": "/Root/Box", "kind": "generic", "seed": 3])
        #expect(generic["kind"].stringValue == "generic")
        _ = await callError(server, "auto_rig", ["mesh": "/Root"])   // no points
    }

    @Test func retargetClip() async {
        // Two rigs; author keyframes on the source, retarget onto the target.
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims.append(RigFixtures.rigPrim(path: "/Src"))
        snapshot.rootPrims.append(RigFixtures.rigPrim(path: "/Dst"))
        snapshot.rootPrims.append(RigFixtures.rigPrim(path: "/Empty"))
        let session = EditSession(snapshot: snapshot, strictness: .warn)
        let server = RigFixtures.server(session)
        _ = await callOK(server, "set_keyframe", ["prim": "/Src", "timeCode": 0])
        _ = await callOK(server, "set_keyframe",
                         ["prim": "/Src", "timeCode": 1, "joint": "Hips/Spine",
                          "rotation": [0.92388, 0, 0, 0.38268]])
        let r = await callOK(server, "retarget_clip",
                             ["sourcePrim": "/Src", "targetPrim": "/Dst", "sampleTimes": [0, 0.5, 1]])
        #expect(r["sampleCount"].intValue == 3)
        // Empty sampleTimes → error.
        _ = await callError(server, "retarget_clip",
                            ["sourcePrim": "/Src", "targetPrim": "/Dst", "sampleTimes": []])
        // Source without keyframes → error (hits the no-keyframes branch).
        _ = await callError(server, "retarget_clip",
                            ["sourcePrim": "/Empty", "targetPrim": "/Src", "sampleTimes": [0]])
    }
}

@Suite("`.rig` self-validation")
struct RigValidationTests {
    @Test func renderPoseMarksRendered() async {
        let session = RigFixtures.session()
        let server = RigFixtures.server(session)
        let r = await callOK(server, "render_pose", ["prim": "/Rig"])
        #expect(r["jointCount"].intValue == 3)
        let status = await callOK(server, "rig_status", [:])
        #expect(status["lastRendered"].boolValue == true)
    }

    @Test func assessMotionMeasuresKeyframes() async {
        let server = RigFixtures.server(RigFixtures.session())
        // No keyframes yet → no measurement.
        let none = await callOK(server, "assess_motion", ["prim": "/Rig"])
        #expect(none["measured"].isNull)
        // Author two keyframes → measurable.
        _ = await callOK(server, "set_keyframe", ["prim": "/Rig", "timeCode": 0])
        _ = await callOK(server, "set_keyframe",
                         ["prim": "/Rig", "timeCode": 1, "joint": "Hips/Spine", "rotation": [0.92388, 0, 0, 0.38268]])
        let measured = await callOK(server, "assess_motion", ["prim": "/Rig", "footJoints": [2]])
        #expect(measured["measured"].doubleValue != nil)
        #expect(measured["smoothness"].doubleValue != nil)
    }

    @Test func reviewGateAcceptsAndRejects() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callOK(server, "set_keyframe", ["prim": "/Rig", "timeCode": 0])
        _ = await callOK(server, "set_keyframe",
                         ["prim": "/Rig", "timeCode": 1, "joint": "Hips/Spine", "rotation": [0.92388, 0, 0, 0.38268]])
        _ = await callOK(server, "assess_motion", ["prim": "/Rig"])
        _ = await callOK(server, "render_pose", ["prim": "/Rig"])
        let accepted = await callOK(server, "rig_review", ["decision": "continue", "subjectiveScore": 0.85])
        #expect(accepted["accepted"].boolValue == true)

        // A fresh server with no render/measurement → rejected continue.
        let bare = RigFixtures.server(RigFixtures.session())
        let rejected = await callOK(bare, "rig_review", ["decision": "continue", "subjectiveScore": 0.2, "motionQuality": 0.1])
        #expect(rejected["accepted"].boolValue == false)
        #expect((rejected["reasons"].arrayValue?.count ?? 0) >= 1)

        // Non-continue decisions pass.
        let stop = await callOK(bare, "rig_review", ["decision": "stop"])
        #expect(stop["accepted"].boolValue == true)
        _ = await callError(bare, "rig_review", ["decision": "bogus"])
    }

    @Test func assessMotionSingleKeyframeReportsTooFewSamples() async {
        let server = RigFixtures.server(RigFixtures.session())
        _ = await callOK(server, "set_keyframe", ["prim": "/Rig", "timeCode": 0])
        let r = await callOK(server, "assess_motion", ["prim": "/Rig"])
        #expect(r["measured"].isNull)
        #expect(r["reason"].stringValue == "fewer than two samples")
    }

    @Test func rigStorePersistsAndRestores() async {
        let dir = Fixtures.tempDirectory()
        let first = RigStore(workDirectory: dir)
        await first.update { $0.currentClip = "walk"; $0.canonicalMapBound = true; $0.lastMotionQuality = 0.8 }
        // A fresh store over the same directory restores the persisted state.
        let restored = RigStore(workDirectory: dir)
        #expect(await restored.state.currentClip == "walk")
        #expect(await restored.state.canonicalMapBound == true)
        // A store with no work directory stays ephemeral (no persistence, no restore).
        let ephemeral = RigStore(workDirectory: nil)
        await ephemeral.update { $0.currentClip = "run" }
        #expect(await ephemeral.state.currentClip == "run")
    }

    @Test func rigGroupIsDiscoverable() async {
        let server = RigFixtures.server(RigFixtures.session())
        #expect(server.toolNames.contains("list_joints"))
        #expect(server.toolNames.contains("assess_motion"))
    }
}
