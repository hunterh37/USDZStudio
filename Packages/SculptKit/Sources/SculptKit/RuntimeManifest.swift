import Foundation
import MechanismKit

/// The "action-ready" runtime layer img2threejs exposes on the built object as
/// `root.userData.sculptRuntime`. Here it is serialized to JSON and authored
/// onto the sculpt root prim as a custom `sculptRuntime` string attribute in
/// the interaction pass, so downstream RealityKit tooling can discover nodes,
/// sockets, colliders, and destruction groups.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public var nodes: [String]
    public var sockets: [Socket]
    /// Rigid articulations (hinges/sliders) exposed to runtime tooling.
    public var joints: [Joint]
    public var colliders: [Collider]
    public var destructionGroups: [DestructionGroup]

    public init(nodes: [String], sockets: [Socket], joints: [Joint] = [],
                colliders: [Collider], destructionGroups: [DestructionGroup]) {
        self.nodes = nodes
        self.sockets = sockets
        self.joints = joints
        self.colliders = colliders
        self.destructionGroups = destructionGroups
    }

    /// Derive the manifest from a spec: every component node plus its runtime
    /// annotations.
    public init(spec: ObjectSculptSpec) {
        self.init(
            nodes: spec.allNodes.map(\.name),
            sockets: spec.sockets,
            joints: spec.joints,
            colliders: spec.colliders,
            destructionGroups: spec.destructionGroups)
    }

    /// Deterministic JSON (sorted keys) for authoring onto the stage.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// True when the manifest carries enough to drive runtime interaction:
    /// at least one socket, collider, or joint.
    public var isActionable: Bool { !sockets.isEmpty || !colliders.isEmpty || !joints.isEmpty }
}
