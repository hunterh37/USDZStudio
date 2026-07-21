import Foundation
import simd
import USDCore
import EditingKit
import RigKit

/// Cross-call agent state for the `.rig` tool group, persisted so a rig survives a server restart
/// (parity with `SculptStore`). `nil` workDirectory disables persistence (ephemeral test store).
public actor RigStore {
    public struct State: Codable, Sendable, Equatable {
        public var activeRigPath: String?
        public var canonicalMapBound: Bool = false
        public var currentClip: String?
        public var lastMotionQuality: Double?
        public var motionQualityFloor: Double = MotionQuality.defaultFloor
        public var lastRendered: Bool = false
        public var lastGateReasons: [String] = []
    }

    public private(set) var state = State()
    let workDirectory: URL?

    public init(workDirectory: URL? = nil) {
        self.workDirectory = workDirectory
        guard let dir = workDirectory,
              let data = try? Data(contentsOf: Self.stateURL(dir)),
              let restored = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = restored
    }

    static func stateURL(_ dir: URL) -> URL { dir.appendingPathComponent("rig-state.json") }

    func update(_ mutate: (inout State) -> Void) {
        mutate(&state)
        persist()
    }

    private func persist() {
        guard let dir = workDirectory, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL(dir))
    }
}

/// The `.rig` MCP tool group: discover a rig, identify canonical bones, author poses/keys/weights,
/// measure motion quality, and self-validate — thin handlers over `RigKit` + `EditSession`.
public enum RigTools {
    // MARK: stage ↔ RigKit helpers

    /// The active rig target: the `prim` argument, else the store's active rig.
    static func target(_ args: JSONValue, session: EditSession, active: String?) throws -> PrimPath {
        if args["prim"].stringValue != nil { return try session.resolve(args, key: "prim") }
        if let active, let path = PrimPath(active), session.stage.prim(at: path) != nil { return path }
        throw ToolError.invalidParams("no rig target — pass 'prim' or identify a skeleton first")
    }

    /// Parse a `Skeleton` from a rig prim's `joints` + `restTransforms`.
    static func skeleton(at path: PrimPath, session: EditSession) throws -> Skeleton {
        guard let prim = session.stage.prim(at: path) else { throw ToolError.primNotFound(path.description) }
        guard case let .tokenArray(joints)? = prim.attribute(named: "joints")?.value else {
            throw ToolError.invalidParams("\(path) has no 'joints' token[] — not a skeleton")
        }
        guard case let .matrix4dArray(rest)? = prim.attribute(named: "restTransforms")?.value,
              let skel = Skeleton(jointPaths: joints, restTransformsFlat: rest) else {
            throw ToolError.invalidParams("\(path) has no valid 'restTransforms' matrix4d[]")
        }
        return skel
    }

    static func flat(_ prim: Prim, _ name: String) -> [Double]? {
        switch prim.attribute(named: name)?.value {
        case .float3Array(let a): return a
        case .quatfArray(let a): return a
        default: return nil
        }
    }

    /// The current default-time pose authored on the prim, or the rest pose when none is present.
    static func currentPose(_ prim: Prim, _ skeleton: Skeleton) -> Pose {
        let n = skeleton.jointCount
        guard let t = flat(prim, "translations"), t.count == n * 3 else { return Pose(rest: skeleton) }
        let r = flat(prim, "rotations")
        let s = flat(prim, "scales")
        var locals: [RigTransform] = []
        for i in 0..<n {
            let tr = Vec3(t[i * 3], t[i * 3 + 1], t[i * 3 + 2])
            let rot: Quat = (r?.count == n * 4)
                ? Quat(w: r![i * 4], x: r![i * 4 + 1], y: r![i * 4 + 2], z: r![i * 4 + 3]) : .identity
            let sc: Vec3 = (s?.count == n * 3) ? Vec3(s![i * 3], s![i * 3 + 1], s![i * 3 + 2]) : Vec3(1, 1, 1)
            locals.append(RigTransform(translation: tr, rotation: rot, scale: sc))
        }
        return Pose(locals: locals)
    }

    /// Whole-pose keyframes authored on the prim → (poses, times), or nil if not animated.
    static func sampledPoses(_ prim: Prim, _ skeleton: Skeleton) -> (poses: [Pose], times: [Double])? {
        guard let tSamples = prim.attribute(named: "translations")?.timeSamples, !tSamples.isEmpty else { return nil }
        let rSamples = prim.attribute(named: "rotations")?.timeSamples ?? []
        let sSamples = prim.attribute(named: "scales")?.timeSamples ?? []
        let n = skeleton.jointCount
        var poses: [Pose] = []
        var times: [Double] = []
        for (idx, ts) in tSamples.enumerated() {
            guard case let .float3Array(t) = ts.value, t.count == n * 3 else { continue }
            let r: [Double]? = { if idx < rSamples.count, case let .quatfArray(a) = rSamples[idx].value { return a }; return nil }()
            let s: [Double]? = { if idx < sSamples.count, case let .float3Array(a) = sSamples[idx].value { return a }; return nil }()
            var locals: [RigTransform] = []
            for i in 0..<n {
                let tr = Vec3(t[i * 3], t[i * 3 + 1], t[i * 3 + 2])
                let rot: Quat = (r?.count == n * 4)
                    ? Quat(w: r![i * 4], x: r![i * 4 + 1], y: r![i * 4 + 2], z: r![i * 4 + 3]) : .identity
                let sc: Vec3 = (s?.count == n * 3) ? Vec3(s![i * 3], s![i * 3 + 1], s![i * 3 + 2]) : Vec3(1, 1, 1)
                locals.append(RigTransform(translation: tr, rotation: rot, scale: sc))
            }
            poses.append(Pose(locals: locals))
            times.append(ts.time)
        }
        return poses.count >= 1 ? (poses, times) : nil
    }

    static func vec3(_ v: JSONValue) -> Vec3? {
        guard let a = v.doubleArrayValue, a.count == 3 else { return nil }
        return Vec3(a[0], a[1], a[2])
    }

    static func jointIndex(_ arg: JSONValue, in skeleton: Skeleton) -> Int? {
        if let i = arg.intValue, i >= 0, i < skeleton.jointCount { return i }
        if let p = arg.stringValue { return skeleton.index(ofPath: p) ?? skeleton.index(ofID: p) }
        return nil
    }

    // MARK: registration

    public static func register(on server: MCPServer, session: EditSession,
                                store: RigStore, workDirectory: URL?) {
        registerIntrospection(on: server, session: session, store: store)
        registerAuthoring(on: server, session: session, store: store)
        registerValidation(on: server, session: session, store: store)
    }

    static func registerIntrospection(on server: MCPServer, session: EditSession, store: RigStore) {
        server.register(MCPTool(
            name: "list_joints", group: .rig,
            description: "List a UsdSkel skeleton's joints (path, parent, child count, rest translation). How the agent sees the rig instead of guessing joint paths.",
            inputSchema: Schema.object(["prim": Schema.primRef])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let skel = try skeleton(at: path, session: session)
            await store.update { $0.activeRigPath = path.description }
            let joints = skel.joints.enumerated().map { (i, j) -> JSONValue in
                .object([
                    "index": .number(Double(i)),
                    "path": .string(j.path),
                    "parent": j.parent.map { .number(Double($0)) } ?? .null,
                    "childCount": .number(Double(skel.children(of: i).count)),
                    "restTranslation": .array([j.restLocal.translation.x, j.restLocal.translation.y, j.restLocal.translation.z].map { .number($0) }),
                ])
            }
            return .object(["prim": .string(path.description), "jointCount": .number(Double(skel.jointCount)),
                            "joints": .array(joints)])
        })

        server.register(MCPTool(
            name: "identify_skeleton", group: .rig,
            description: "Fuzzy-match an authored skeleton to the canonical humanoid standard. Returns, per canonical bone, the best joint path + confidence (0…1) + alternates; low-confidence/unmatched bones are reported, never silently mapped.",
            inputSchema: Schema.object(["prim": Schema.primRef])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let skel = try skeleton(at: path, session: session)
            let mapping = HumanoidMap.identify(skel)
            await store.update { $0.activeRigPath = path.description; $0.canonicalMapBound = true }
            var matches: [String: JSONValue] = [:]
            for (name, m) in mapping.matches {
                matches[name] = .object([
                    "jointPath": m.jointPath.map { .string($0) } ?? .null,
                    "confidence": .number(m.confidence),
                    "alternates": .array(m.alternates.map { .string($0) }),
                ])
            }
            return .object([
                "prim": .string(path.description),
                "matches": .object(matches),
                "lowConfidence": .array(mapping.lowConfidence.sorted().map { .string($0) }),
            ])
        })

        server.register(MCPTool(
            name: "rig_status", group: .rig,
            description: "Current agent rig state: active rig, whether a canonical map is bound, current clip, last measuredMotionQuality + the active floor, and outstanding self-validation reasons.",
            inputSchema: Schema.object([:])
        ) { _ in
            let s = await store.state
            return .object([
                "activeRig": s.activeRigPath.map { .string($0) } ?? .null,
                "canonicalMapBound": .bool(s.canonicalMapBound),
                "currentClip": s.currentClip.map { .string($0) } ?? .null,
                "lastMotionQuality": s.lastMotionQuality.map { .number($0) } ?? .null,
                "motionQualityFloor": .number(s.motionQualityFloor),
                "lastRendered": .bool(s.lastRendered),
                "outstandingGateReasons": .array(s.lastGateReasons.map { .string($0) }),
            ])
        })
    }

    static func registerAuthoring(on server: MCPServer, session: EditSession, store: RigStore) {
        server.register(MCPTool(
            name: "set_joint_pose", group: .rig,
            description: "Author one joint's local transform (undoable). Merges the provided translation/rotation/scale onto the current pose and re-authors the pose channels.",
            inputSchema: Schema.object([
                "prim": Schema.primRef, "joint": Schema.string("joint path or index"),
                "translation": Schema.vec3, "rotation": Schema.array(of: .object(["type": "number"]), "[w, x, y, z]"),
                "scale": Schema.vec3,
            ], required: ["joint"])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let prim = session.stage.prim(at: path)!
            let skel = try skeleton(at: path, session: session)
            guard let j = jointIndex(args["joint"], in: skel) else {
                throw ToolError.invalidParams("unknown joint '\(args["joint"].stringValue ?? "?")'")
            }
            var pose = currentPose(prim, skel)
            var local = pose.local(j)
            if let t = vec3(args["translation"]) { local.translation = t }
            if let r = args["rotation"].doubleArrayValue, r.count == 4 {
                local.rotation = Quat(w: r[0], x: r[1], y: r[2], z: r[3]).normalized
            }
            if let s = vec3(args["scale"]) { local.scale = s }
            pose = pose.setting(local, at: j)
            let outcome = try session.mutate(AuthorSkelPoseCommand(path: path, pose: pose, existing: prim))
            await store.update { $0.activeRigPath = path.description; $0.lastRendered = false }
            return outcome.asJSON(extra: ["joint": .number(Double(j))])
        })

        server.register(MCPTool(
            name: "solve_ik", group: .rig,
            description: "Run the analytic 2-bone / CCD / FABRIK solver and author the resulting pose. Returns the SolveResult (converged, iterations, residual) verbatim — a non-converging solve is a reported outcome to handle, never a silent bad pose.",
            inputSchema: Schema.object([
                "prim": Schema.primRef,
                "chain": Schema.array(of: .object(["type": "string"]), "joint paths root→effector"),
                "target": Schema.vec3, "poleVector": Schema.vec3,
                "solver": Schema.string("twoBone | ccd | fabrik (default ccd; twoBone needs a 3-joint chain)"),
            ], required: ["chain", "target"])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let prim = session.stage.prim(at: path)!
            let skel = try skeleton(at: path, session: session)
            guard let chainArgs = args["chain"].arrayValue, chainArgs.count >= 2 else {
                throw ToolError.invalidParams("'chain' must list at least two joints")
            }
            var indices: [Int] = []
            for c in chainArgs {
                guard let i = jointIndex(c, in: skel) else {
                    throw ToolError.invalidParams("unknown chain joint '\(c.stringValue ?? "?")'")
                }
                indices.append(i)
            }
            guard let target = vec3(args["target"]) else { throw ToolError.invalidParams("'target' must be [x, y, z]") }
            let chain = IKChain(joints: indices, target: target, poleVector: vec3(args["poleVector"]))
            let kind = IKSolverKind(parsing: args["solver"].stringValue)
            let result = IKSolvers.solve(skel, pose: currentPose(prim, skel), chain: chain, kind: kind)
            let outcome = try session.mutate(AuthorSkelPoseCommand(path: path, pose: result.pose, existing: prim))
            await store.update { $0.activeRigPath = path.description; $0.lastRendered = false }
            return outcome.asJSON(extra: [
                "converged": .bool(result.converged),
                "iterations": .number(Double(result.iterations)),
                "residual": .number(result.residual),
            ])
        })

        server.register(MCPTool(
            name: "set_keyframe", group: .rig,
            description: "Set a keyframe at timeCode for the current pose (optionally editing one joint first). Writes into the channels' .timeSamples (the closed time-sampled round-trip path).",
            inputSchema: Schema.object([
                "prim": Schema.primRef, "timeCode": Schema.number("time code"),
                "joint": Schema.string("optional joint path/index to edit before keying"),
                "translation": Schema.vec3, "rotation": Schema.array(of: .object(["type": "number"]), "[w, x, y, z]"),
                "scale": Schema.vec3,
            ], required: ["timeCode"])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let prim = session.stage.prim(at: path)!
            let skel = try skeleton(at: path, session: session)
            guard let time = args["timeCode"].doubleValue else { throw ToolError.invalidParams("'timeCode' is required") }
            var pose = currentPose(prim, skel)
            if let j = jointIndex(args["joint"], in: skel) {
                var local = pose.local(j)
                if let t = vec3(args["translation"]) { local.translation = t }
                if let r = args["rotation"].doubleArrayValue, r.count == 4 {
                    local.rotation = Quat(w: r[0], x: r[1], y: r[2], z: r[3]).normalized
                }
                if let s = vec3(args["scale"]) { local.scale = s }
                pose = pose.setting(local, at: j)
            }
            let outcome = try session.mutate(SetSkelKeyframeCommand(path: path, timeCode: time, pose: pose, existing: prim))
            await store.update { $0.activeRigPath = path.description }
            return outcome.asJSON(extra: ["timeCode": .number(time)])
        })

        server.register(MCPTool(
            name: "create_clip", group: .rig,
            description: "Set the stage animation time range (the clip window) and record the active clip name.",
            inputSchema: Schema.object([
                "name": Schema.string("clip name"),
                "startTimeCode": Schema.number("start"), "endTimeCode": Schema.number("end"),
            ], required: ["name", "startTimeCode", "endTimeCode"])
        ) { args in
            guard let name = args["name"].stringValue,
                  let start = args["startTimeCode"].doubleValue, let end = args["endTimeCode"].doubleValue else {
                throw ToolError.invalidParams("'name', 'startTimeCode', 'endTimeCode' are required")
            }
            let outcome = try session.mutate(SetClipRangeCommand(
                name: name, startTimeCode: start, endTimeCode: end,
                current: session.stage.currentSnapshot.metadata))
            await store.update { $0.currentClip = name }
            return outcome.asJSON(extra: ["clip": .string(name)])
        })

        server.register(MCPTool(
            name: "solve_weights", group: .rig,
            description: "Heat-diffusion / bone-glow skin weight solve binding a mesh to the rig, with normalize/prune/clamp to the export-profile influence cap.",
            inputSchema: Schema.object([
                "prim": Schema.primRef, "mesh": Schema.primRef,
                "maxInfluences": Schema.integer("influence cap (default 4)"),
            ], required: ["mesh"])
        ) { args in
            let active = await store.state.activeRigPath
            let rigPath = try target(args, session: session, active: active)
            let skel = try skeleton(at: rigPath, session: session)
            let meshPath = try session.resolve(args, key: "mesh")
            let meshPrim = session.stage.prim(at: meshPath)!
            guard case let .float3Array(points)? = meshPrim.attribute(named: "points")?.value, !points.isEmpty else {
                throw ToolError.invalidParams("\(meshPath) has no 'points' float3[]")
            }
            var verts: [Vec3] = []
            var i = 0
            while i + 2 < points.count { verts.append(Vec3(points[i], points[i + 1], points[i + 2])); i += 3 }
            let cap = args["maxInfluences"].intValue ?? 4
            let skin = WeightSolve.solve(mesh: RigMesh(points: verts), skeleton: skel, maxInfluences: cap)
            let flat = skin.flattened(influencesPerVertex: cap)
            let outcome = try session.mutate(AuthorSkinCommand(
                path: meshPath, indices: flat.indices, weights: flat.weights,
                influencesPerVertex: cap, existing: meshPrim))
            return outcome.asJSON(extra: [
                "vertexCount": .number(Double(skin.vertexCount)),
                "maxInfluences": .number(Double(cap)),
            ])
        })

        server.register(MCPTool(
            name: "auto_rig", group: .rig,
            description: "One-click skeleton fit for an unrigged mesh (humanoid landmark or generic spine). Returns the proposed skeleton for the confirm-&-adjust preview. Deterministic given seed; does not mutate the stage.",
            inputSchema: Schema.object([
                "mesh": Schema.primRef, "kind": Schema.string("humanoid | generic"),
                "seed": Schema.integer("determinism seed"),
            ], required: ["mesh"])
        ) { args in
            let meshPath = try session.resolve(args, key: "mesh")
            let meshPrim = session.stage.prim(at: meshPath)!
            guard case let .float3Array(points)? = meshPrim.attribute(named: "points")?.value, !points.isEmpty else {
                throw ToolError.invalidParams("\(meshPath) has no 'points' float3[]")
            }
            var verts: [Vec3] = []
            var i = 0
            while i + 2 < points.count { verts.append(Vec3(points[i], points[i + 1], points[i + 2])); i += 3 }
            let kind: AutoRigKind = args["kind"].stringValue == "generic" ? .generic : .humanoid
            let skel = SkeletonFit.fit(RigMesh(points: verts), kind: kind, seed: args["seed"].intValue ?? 0)
            let joints = skel.joints.map { j -> JSONValue in
                .object(["path": .string(j.path), "parent": j.parent.map { .number(Double($0)) } ?? .null])
            }
            return .object(["kind": .string(kind.rawValue), "jointCount": .number(Double(skel.jointCount)),
                            "joints": .array(joints)])
        })

        server.register(MCPTool(
            name: "retarget_clip", group: .rig,
            description: "Retarget an authored clip from a source rig onto a target rig via the canonical bone map (rest-pose reconciliation + hip-height normalization). Authors the retargeted keyframes onto the target.",
            inputSchema: Schema.object([
                "sourcePrim": Schema.primRef, "targetPrim": Schema.primRef,
                "sampleTimes": Schema.array(of: .object(["type": "number"]), "time codes to sample"),
            ], required: ["sourcePrim", "targetPrim", "sampleTimes"])
        ) { args in
            let sourcePath = try session.resolve(args, key: "sourcePrim")
            let targetPath = try session.resolve(args, key: "targetPrim")
            let sourceSkel = try skeleton(at: sourcePath, session: session)
            let targetSkel = try skeleton(at: targetPath, session: session)
            let sourcePrim = session.stage.prim(at: sourcePath)!
            guard let sampled = sampledPoses(sourcePrim, sourceSkel) else {
                throw ToolError.invalidParams("source clip has no keyframes to retarget")
            }
            guard let times = args["sampleTimes"].doubleArrayValue, !times.isEmpty else {
                throw ToolError.invalidParams("'sampleTimes' must be a non-empty number array")
            }
            // Build a source Clip from the sampled whole-pose keyframes.
            var channels = [[Keyframe]](repeating: [], count: sourceSkel.jointCount)
            for (idx, pose) in sampled.poses.enumerated() {
                for j in 0..<sourceSkel.jointCount {
                    channels[j].append(Keyframe(time: sampled.times[idx], transform: pose.local(j)))
                }
            }
            let sourceClip = Clip(name: "retarget", channels: channels,
                                  startTime: sampled.times.min()!, endTime: sampled.times.max()!)
            let retargeted = Retargeter.retarget(
                sourceClip: sourceClip, source: sourceSkel, sourceMapping: HumanoidMap.identify(sourceSkel),
                target: targetSkel, targetMapping: HumanoidMap.identify(targetSkel), sampleTimes: times)
            // Author each sampled retargeted pose as a keyframe on the target.
            let rest = Pose(rest: targetSkel)
            var outcomeJSON = JSONValue.null
            for t in times.sorted() {
                let pose = retargeted.sample(at: t, rest: rest)
                let prim = session.stage.prim(at: targetPath)!
                let outcome = try session.mutate(SetSkelKeyframeCommand(path: targetPath, timeCode: t, pose: pose, existing: prim))
                outcomeJSON = outcome.asJSON()
            }
            await store.update { $0.activeRigPath = targetPath.description }
            return .object(["target": .string(targetPath.description),
                            "sampleCount": .number(Double(times.count)), "last": outcomeJSON])
        })
    }

    static func registerValidation(on server: MCPServer, session: EditSession, store: RigStore) {
        server.register(MCPTool(
            name: "render_pose", group: .rig,
            description: "Evidence for the continue-gate: a stats summary of the current (or sampled) pose — joint count and world-space bounds. Marks that a render was produced.",
            inputSchema: Schema.object(["prim": Schema.primRef])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let prim = session.stage.prim(at: path)!
            let skel = try skeleton(at: path, session: session)
            let world = currentPose(prim, skel).worldPositions(skel)
            var lo = world.first ?? .zero, hi = world.first ?? .zero
            for p in world { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            await store.update { $0.lastRendered = true }
            return .object([
                "jointCount": .number(Double(skel.jointCount)),
                "boundsMin": .array([lo.x, lo.y, lo.z].map { .number($0) }),
                "boundsMax": .array([hi.x, hi.y, hi.z].map { .number($0) }),
            ])
        })

        server.register(MCPTool(
            name: "assess_motion", group: .rig,
            description: "Deterministic motion-quality metric over the authored keyframes: measuredMotionQuality plus sub-scores (smoothness/jerk, foot-slide, interpenetration, limit-compliance, seam-continuity, naturalness). No keyframes → no measurement reported.",
            inputSchema: Schema.object(["prim": Schema.primRef,
                                        "footJoints": Schema.array(of: .object(["type": "integer"]), "planted-foot joint indices")])
        ) { args in
            let active = await store.state.activeRigPath
            let path = try target(args, session: session, active: active)
            let prim = session.stage.prim(at: path)!
            let skel = try skeleton(at: path, session: session)
            guard let sampled = sampledPoses(prim, skel) else {
                await store.update { $0.lastMotionQuality = nil }
                return .object(["measured": .null, "reason": .string("no keyframes to sample")])
            }
            let footJoints = (args["footJoints"].arrayValue ?? []).compactMap { $0.intValue }
            let sample = MotionSample(skeleton: skel, poses: sampled.poses, times: sampled.times, footJoints: footJoints)
            guard let report = MotionQuality.assess(sample) else {
                await store.update { $0.lastMotionQuality = nil }
                return .object(["measured": .null, "reason": .string("fewer than two samples")])
            }
            await store.update { $0.lastMotionQuality = report.measuredMotionQuality }
            return .object([
                "measured": .number(report.measuredMotionQuality),
                "smoothness": .number(report.smoothness),
                "footSlide": .number(report.footSlide),
                "interpenetration": .number(report.interpenetration),
                "limitCompliance": .number(report.limitCompliance),
                "seamContinuity": .number(report.seamContinuity),
                "naturalness": .number(report.naturalness),
            ])
        })

        server.register(MCPTool(
            name: "rig_review", group: .rig,
            description: "Record one RigDecision (continue | refinePose | resolve | requestInput | stop) and run the continue-gate: a continue requires a render, an assess_motion measurement ≥ floor, and a subjective score ≥ threshold.",
            inputSchema: Schema.object([
                "decision": Schema.string("continue | refinePose | resolve | requestInput | stop"),
                "subjectiveScore": Schema.number("subjective vision score 0…1"),
                "motionQuality": Schema.number("override the stored measuredMotionQuality"),
            ], required: ["decision"])
        ) { args in
            guard let raw = args["decision"].stringValue, let decision = RigDecision(rawValue: raw) else {
                throw ToolError.invalidParams("'decision' must be one of \(RigDecision.allCases.map(\.rawValue))")
            }
            let s = await store.state
            let quality = args["motionQuality"].doubleValue ?? s.lastMotionQuality
            let evidence = RigEvidence(hasRender: s.lastRendered,
                                       measuredMotionQuality: quality,
                                       subjectiveScore: args["subjectiveScore"].doubleValue)
            let result = RigReviewGate.evaluate(decision: decision, evidence: evidence,
                                                motionQualityFloor: s.motionQualityFloor)
            await store.update { $0.lastGateReasons = result.reasons }
            return .object([
                "decision": .string(decision.rawValue),
                "accepted": .bool(result.accepted),
                "reasons": .array(result.reasons.map { .string($0) }),
            ])
        })
    }
}
