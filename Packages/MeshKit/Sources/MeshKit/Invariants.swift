import Foundation

/// Machine-checkable correctness invariants (specs/mesh-editing.md §Correctness
/// Invariants). Used by every op's test suite and as debug assertions.
public enum MeshInvariants {

    public struct Violation: Error, CustomStringConvertible, Equatable {
        public let rule: String
        public let detail: String
        public var description: String { "[\(rule)] \(detail)" }
    }

    public static let epsilon = 1e-9

    /// Invariant 1 helper: V − E + F.
    public static func eulerCharacteristic(of mesh: HalfEdgeMesh) -> Int {
        mesh.vertexCount - mesh.edgeCount + mesh.faceCount
    }

    /// Invariants 2–4. Returns all violations (empty == healthy).
    public static func violations(in mesh: HalfEdgeMesh, allowBoundaries: Bool = true) -> [Violation] {
        var out: [Violation] = []
        let edgeFaces = mesh.edgeFaceMap

        // 2. Manifoldness: every edge borders ≤ 2 faces; no isolated vertices.
        for (edge, faces) in edgeFaces where faces.count > 2 {
            out.append(.init(rule: "manifold",
                             detail: "edge (\(edge.a.rawValue),\(edge.b.rawValue)) borders \(faces.count) faces"))
        }
        var referenced = Set<VertexID>()
        for loop in mesh.faceLoops.values { referenced.formUnion(loop) }
        for v in mesh.positions.keys where !referenced.contains(v) {
            out.append(.init(rule: "manifold", detail: "isolated vertex \(v.rawValue)"))
        }
        if !allowBoundaries {
            for (edge, faces) in edgeFaces where faces.count == 1 {
                out.append(.init(rule: "closed",
                                 detail: "boundary edge (\(edge.a.rawValue),\(edge.b.rawValue))"))
            }
        }

        // 3. Winding consistency: the two faces sharing an interior edge must
        // traverse it in opposite directions.
        var directed: [EdgeKey: [(FaceID, Bool)]] = [:] // Bool: traversed a→b
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            for i in loop.indices {
                let u = loop[i], w = loop[(i + 1) % loop.count]
                let key = EdgeKey(u, w)
                directed[key, default: []].append((f, u == key.a))
            }
        }
        for (edge, uses) in directed where uses.count == 2 {
            if uses[0].1 == uses[1].1 {
                out.append(.init(rule: "winding",
                                 detail: "faces \(uses[0].0.rawValue),\(uses[1].0.rawValue) traverse edge (\(edge.a.rawValue),\(edge.b.rawValue)) in the same direction"))
            }
        }

        // 4. No degenerates.
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            if loop.count < 3 {
                out.append(.init(rule: "degenerate", detail: "face \(f.rawValue) has \(loop.count) vertices"))
            }
            if Set(loop).count != loop.count {
                out.append(.init(rule: "degenerate", detail: "face \(f.rawValue) repeats a vertex"))
            }
            for i in loop.indices {
                let p = mesh.positions[loop[i]]!, q = mesh.positions[loop[(i + 1) % loop.count]]!
                if simd_length(p - q) <= epsilon {
                    out.append(.init(rule: "degenerate",
                                     detail: "face \(f.rawValue) contains a zero-length edge"))
                }
            }
            if mesh.faceArea(f) <= epsilon {
                out.append(.init(rule: "degenerate", detail: "face \(f.rawValue) has zero area"))
            }
        }

        // Referential integrity (implied by all invariants).
        for (f, loop) in mesh.faceLoops {
            for v in loop where mesh.positions[v] == nil {
                out.append(.init(rule: "integrity",
                                 detail: "face \(f.rawValue) references missing vertex \(v.rawValue)"))
            }
        }
        return out
    }

    public static func assertHealthy(_ mesh: HalfEdgeMesh, allowBoundaries: Bool = true) throws {
        let v = violations(in: mesh, allowBoundaries: allowBoundaries)
        if let first = v.first { throw first }
    }
}
