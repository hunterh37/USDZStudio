import Foundation
import USDCore
import EditingKit
import MechanismKit

/// Rigid-articulation tools: give a part a hinge or slider and drive it open /
/// closed. These let a coding agent build a *fully hinged, swingable object* —
/// an AirPods-case lid, a chest, a door, a drawer — via proper Xform ops on the
/// prim (PRD §5.3), authored RealityKit/QuickLook-clean (specs/articulation-mechanisms.md).
public enum JointTools {

    public static func register(on server: MCPServer, session: EditSession) {

        server.register(MCPTool(
            name: "create_joint", group: .mutate,
            description: """
            Make a part open/close/swing about a fixed axis — a lid, door, cap, or drawer. \
            Inserts a pivot Xform on the hinge line so the part rotates (revolute) or slides \
            (prismatic) about the RIGHT edge, not its centre, and keeps its closed placement \
            exactly. Author axis + a pivot point ON the hinge line, both in the part's parent \
            local space; closed is 0 and open is `openValue` (degrees for revolute, scene units \
            for prismatic). SIGN CONVENTION: a positive revolute openValue rotates the part \
            counter-clockwise about `axis` per the right-hand rule (thumb along axis, fingers \
            curl in +rotation); a positive prismatic openValue slides along +axis. Rather than \
            reasoning the sign out, pass `openTowards` — a point (same space as pivot) the part \
            should move TOWARD when opening — and the sign is picked automatically (a hood \
            opens toward a point above the car, a drawer toward a point in front of the chest). \
            Drive it afterwards with set_joint_state. Returns the pivot path.
            """,
            inputSchema: Schema.object([
                "target": Schema.primRef,
                "kind": Schema.string("revolute (hinge, default) | prismatic (slider)"),
                "axis": Schema.vec3,
                "pivot": Schema.vec3,
                "openValue": Schema.number("open angle in degrees (revolute) or distance in scene units (prismatic); sign follows the right-hand rule about axis (auto-corrected when openTowards is given)"),
                "openTowards": Schema.vec3,
                "name": Schema.string("optional joint name (default '<part>Hinge' / '<part>Slide')"),
            ], required: ["target", "axis", "pivot", "openValue"])
        ) { args in
            let target = try session.resolve(args, key: "target")
            let kind: JointKind = args["kind"].stringValue == "prismatic" ? .prismatic : .revolute
            guard let axis = args["axis"].doubleArrayValue, axis.count == 3 else {
                throw ToolError.invalidParams("'axis' must be [x, y, z]")
            }
            guard let pivot = args["pivot"].doubleArrayValue, pivot.count == 3 else {
                throw ToolError.invalidParams("'pivot' must be [x, y, z]")
            }
            guard var openValue = args["openValue"].doubleValue else {
                throw ToolError.invalidParams("'openValue' is required")
            }
            var signNote: String?
            if let towards = args["openTowards"].doubleArrayValue {
                guard towards.count == 3 else {
                    throw ToolError.invalidParams("'openTowards' must be [x, y, z]")
                }
                // Pick the openValue sign that moves the part toward the hint
                // (issue #160): agents were guessing the right-hand-rule sign
                // and swinging hoods down through bodies.
                if let corrected = openSign(
                    target: target, kind: kind, axis: axis, pivot: pivot,
                    openValue: openValue, towards: towards, session: session
                ) {
                    if corrected != openValue {
                        signNote = "openValue sign flipped to \(corrected) so the part moves toward openTowards"
                    }
                    openValue = corrected
                }
            }
            let name = args["name"].stringValue
                ?? "\(target.name)\(kind == .revolute ? "Hinge" : "Slide")"
            let joint = Joint.openable(name: name, kind: kind, target: target.name,
                                       axis: axis, pivot: pivot, openValue: openValue)

            guard let command = CreateJointCommand.make(target: target, joint: joint, in: session.stage) else {
                throw ToolError.invalidParams(
                    "cannot add a joint to \(target): the prim must be a non-root part and axis/pivot/openValue must be valid")
            }
            let outcome = try session.mutate(command, moved: [(target, command.movedPartPath)])
            var extra: [String: JSONValue] = [
                "pivotPath": .string(command.pivotPath.description),
                "partPath": .string(command.movedPartPath.description),
                "states": .array(command.joint.states.map { .string($0.name) }),
            ]
            if let signNote { extra["note"] = .string(signNote) }
            return outcome.asJSON(extra: extra)
        })

        registerSetJointState(on: server, session: session)
    }

    /// The openValue whose sign moves the part's centre toward `towards` when
    /// the joint opens, or nil when the geometry gives no usable signal (no
    /// bbox, degenerate axis, or both signs land equally close). All inputs
    /// (`axis`, `pivot`, `towards`) are in the part's parent local space —
    /// they are converted to world space alongside the part's world-space
    /// bbox centre before comparing (issue #160).
    static func openSign(
        target: PrimPath, kind: JointKind, axis: [Double], pivot: [Double],
        openValue: Double, towards: [Double], session: EditSession
    ) -> Double? {
        guard let box = GeometryProbe.worldBBox(of: target, in: session.stage) else { return nil }
        let center = box.center
        let parentMatrix = session.stage.worldMatrix(at: target.parent)
        let pivotW = GeometryProbe.transform(point: pivot, by: parentMatrix)
        let towardsW = GeometryProbe.transform(point: towards, by: parentMatrix)
        // Direction vectors transform as (point + v) - point, dropping translation.
        let axisTipW = GeometryProbe.transform(
            point: zip(pivot, axis).map(+), by: parentMatrix)
        let axisW = zip(axisTipW, pivotW).map(-)
        let axisLength = axisW.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard axisLength > 1e-9 else { return nil }
        let unit = axisW.map { $0 / axisLength }

        func moved(by value: Double) -> [Double] {
            switch kind {
            case .prismatic:
                return zip(center, unit.map { $0 * value }).map(+)
            case .revolute:
                // Rodrigues rotation of the centre about (pivotW, unit).
                let radians = value * .pi / 180
                let v = zip(center, pivotW).map(-)
                let c = cos(radians), s = sin(radians)
                let dot = zip(v, unit).map(*).reduce(0, +)
                let cross = [unit[1] * v[2] - unit[2] * v[1],
                             unit[2] * v[0] - unit[0] * v[2],
                             unit[0] * v[1] - unit[1] * v[0]]
                let rotated = (0..<3).map { i in
                    v[i] * c + cross[i] * s + unit[i] * dot * (1 - c)
                }
                return zip(rotated, pivotW).map(+)
            }
        }
        func distance(_ p: [Double]) -> Double {
            zip(p, towardsW).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
        }
        let positive = distance(moved(by: abs(openValue)))
        let negative = distance(moved(by: -abs(openValue)))
        if abs(positive - negative) < 1e-9 { return nil }
        return positive < negative ? abs(openValue) : -abs(openValue)
    }

    static func registerSetJointState(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "set_joint_state", group: .mutate,
            description: """
            Drive a joint created with create_joint to a named state ('open' / 'closed') or an \
            explicit in-limit value. Pass either the pivot path or the moving part's path as \
            `target`. Re-authors only the pivot's transform, so it is a clean, undoable edit — \
            the "open the door" gesture, and the same seam a state switcher or timeline scrub uses.
            """,
            inputSchema: Schema.object([
                "target": Schema.primRef,
                "state": Schema.string("state name, e.g. 'open' or 'closed'"),
                "value": Schema.number("explicit angle (degrees) or distance (units), within the joint's limits"),
            ], required: ["target"])
        ) { args in
            let given = try session.resolve(args, key: "target")
            // Accept either the pivot itself or the moving part (whose parent is
            // the pivot) — resolve to whichever carries the joint.
            let pivot: PrimPath
            if SetJointStateCommand.jointOnPivot(given, in: session.stage) != nil {
                pivot = given
            } else if !given.isRoot,
                      SetJointStateCommand.jointOnPivot(given.parent, in: session.stage) != nil {
                pivot = given.parent
            } else {
                throw ToolError.invalidParams("\(given) is not a joint pivot (nor a part under one) — create one with create_joint first")
            }

            let command: SetJointStateCommand?
            if let state = args["state"].stringValue {
                command = SetJointStateCommand.make(pivotPath: pivot, state: state, in: session.stage)
            } else if let value = args["value"].doubleValue {
                command = SetJointStateCommand.make(pivotPath: pivot, value: value, in: session.stage)
            } else {
                throw ToolError.invalidParams("pass either 'state' or 'value'")
            }
            guard let command else {
                throw ToolError.invalidParams("unknown state or out-of-limit value for joint at \(pivot)")
            }
            return try session.mutate(command).asJSON(extra: ["pivotPath": .string(pivot.description)])
        })
    }
}
