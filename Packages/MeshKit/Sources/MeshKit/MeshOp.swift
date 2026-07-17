import Foundation

/// Typed failure with precondition diagnostics — failing loudly beats silently
/// producing garbage (specs/mesh-editing.md §Operation contract).
public enum MeshOpError: Error, Equatable, CustomStringConvertible {
    case emptySelection
    case unknownComponent(String)
    case skinnedMeshUnsupported
    case nonManifoldRegion(String)
    case preconditionFailed(String)
    case invariantViolated(String)

    public var description: String {
        switch self {
        case .emptySelection: return "Selection is empty."
        case .unknownComponent(let s): return "Selection references a missing component: \(s)."
        case .skinnedMeshUnsupported:
            return "Mesh has skeletal binding — mesh editing would break weights."
        case .nonManifoldRegion(let s): return "Non-manifold region: \(s)."
        case .preconditionFailed(let s): return "Precondition failed: \(s)."
        case .invariantViolated(let s): return "Post-op invariant violated: \(s)."
        }
    }
}

/// Predicted topology change; each op's tests assert the actual delta matches.
public struct TopologyDelta: Equatable, Sendable {
    public var vertices: Int
    public var edges: Int
    public var faces: Int
    public init(vertices: Int, edges: Int, faces: Int) {
        self.vertices = vertices; self.edges = edges; self.faces = faces
    }
    public var eulerDelta: Int { vertices - edges + faces }
}

public struct MeshOpResult: Sendable {
    public let mesh: HalfEdgeMesh
    public let resultSelection: ComponentSelection
    public let delta: TopologyDelta
}

/// Pure-function op contract. No side effects; throws typed `MeshOpError`.
public protocol MeshOp {
    associatedtype Params
    static var name: String { get }
    static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection, params: Params)
        throws -> MeshOpResult
}

enum OpSupport {
    /// Shared post-op verification: measured delta must match prediction and
    /// the result must pass the invariant suite. Debug-asserted in dev builds,
    /// always thrown as typed errors so agents get a feedback signal.
    static func verify(before: HalfEdgeMesh, after: HalfEdgeMesh, predicted: TopologyDelta) throws {
        let actual = TopologyDelta(
            vertices: after.vertexCount - before.vertexCount,
            edges: after.edgeCount - before.edgeCount,
            faces: after.faceCount - before.faceCount)
        guard actual == predicted else {
            throw MeshOpError.invariantViolated(
                "topology delta mismatch: predicted V\(predicted.vertices) E\(predicted.edges) F\(predicted.faces), got V\(actual.vertices) E\(actual.edges) F\(actual.faces)")
        }
        if let v = MeshInvariants.violations(in: after).first {
            throw MeshOpError.invariantViolated(v.description)
        }
    }
}
