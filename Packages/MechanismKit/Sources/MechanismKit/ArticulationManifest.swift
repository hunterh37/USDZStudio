import Foundation

/// The articulation entries appended to the `sculptRuntime` manifest so
/// downstream RealityKit / QuickLook tooling can discover openable parts and the
/// axis/pivot/limits/states needed to drive them. Pure data + deterministic JSON.
public struct ArticulationManifest: Codable, Sendable, Equatable {
    public var joints: [Joint]

    public init(joints: [Joint]) {
        self.joints = joints
    }

    /// Only the joints that pass validation (no error-severity issues) belong in
    /// the manifest — a malformed joint is dropped rather than advertised.
    public init(validatedFrom joints: [Joint]) {
        self.joints = joints.filter(JointInvariants.isValid)
    }

    /// Deterministic JSON (sorted keys) for authoring onto the stage.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// True when at least one drivable joint is present.
    public var isActionable: Bool { !joints.isEmpty }
}
