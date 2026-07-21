import Foundation

/// Resolves a `RecipeSelector` against the *current* mesh state into a typed
/// `ComponentSelection`. Indices are export-order (`vertexOrder` /
/// `faceOrder`); every out-of-range or wrong-kind reference is a typed error
/// naming what was asked for.
enum SelectorResolver {

    // MARK: - Kind-specific entry points (ops declare what they need)

    static func faces(_ selector: RecipeSelector?, in mesh: HalfEdgeMesh,
                      last: ComponentSelection?) throws -> ComponentSelection {
        let selection = try resolve(selector, in: mesh, last: last, defaultKind: .faces)
        guard case .faces = selection else {
            throw RecipeError(message: "this op needs a face selection, got \(kindName(selection))")
        }
        return selection
    }

    static func edges(_ selector: RecipeSelector?, in mesh: HalfEdgeMesh,
                      last: ComponentSelection?) throws -> ComponentSelection {
        let selection = try resolve(selector, in: mesh, last: last, defaultKind: .edges)
        guard case .edges = selection else {
            throw RecipeError(message: "this op needs an edge selection, got \(kindName(selection))")
        }
        return selection
    }

    static func vertices(_ selector: RecipeSelector?, in mesh: HalfEdgeMesh,
                         last: ComponentSelection?) throws -> ComponentSelection {
        var selection = try resolve(selector, in: mesh, last: last, defaultKind: .vertices)
        // Vertex ops accept a face/edge selection by taking its vertex set —
        // lets "merge the cap I just extruded" read naturally.
        if case .vertices = selection {} else {
            selection = .vertices(try TransformComponents.affectedVertices(of: selection, in: mesh))
        }
        return selection
    }

    static func any(_ selector: RecipeSelector?, in mesh: HalfEdgeMesh,
                    last: ComponentSelection?) throws -> ComponentSelection {
        try resolve(selector, in: mesh, last: last, defaultKind: .faces)
    }

    // MARK: - Core resolution

    private enum Kind { case vertices, edges, faces }

    private static func resolve(_ selector: RecipeSelector?, in mesh: HalfEdgeMesh,
                                last: ComponentSelection?, defaultKind: Kind) throws -> ComponentSelection {
        guard let selector else {
            throw RecipeError(message: "step needs a 'select' (e.g. {\"all\": true}, {\"facing\": [0,1,0]}, {\"last\": true})")
        }
        // Boolean sources count only when true — {"last": false} is "no
        // source", not a source that then resolves to nothing.
        let sources = [selector.all == true, selector.faces != nil, selector.vertices != nil,
                       selector.edges != nil, selector.facing != nil,
                       selector.boundary == true, selector.last == true,
                       // `within` counts as a source only when it stands alone
                       selector.within != nil && selector.facing == nil && selector.all != true]
            .filter { $0 }.count
        guard sources == 1 else {
            throw RecipeError(message: "selector must use exactly one source (all / faces / vertices / edges / facing / within / boundary / last); 'within' may also refine 'all' or 'facing'")
        }

        if selector.last == true {
            guard let last else {
                throw RecipeError(message: "'last' has no previous step result to refer to")
            }
            return last
        }
        if selector.boundary == true {
            let boundary = mesh.boundaryEdges
            guard !boundary.isEmpty else {
                throw RecipeError(message: "'boundary' selected nothing — the mesh is closed")
            }
            return .edges(boundary)
        }
        if let indices = selector.vertices {
            return .vertices(Set(try indices.map { try vertexID(at: $0, in: mesh) }))
        }
        if let pairs = selector.edges {
            var out = Set<EdgeKey>()
            // Membership-only check: the undirected edge key set is enough, so
            // avoid `edgeFaceMap`'s per-edge `[FaceID]` array allocations.
            let known = mesh.edgeSet
            for pair in pairs {
                guard pair.count == 2 else {
                    throw RecipeError(message: "each edge must be a [a, b] vertex-index pair")
                }
                let key = EdgeKey(try vertexID(at: pair[0], in: mesh),
                                  try vertexID(at: pair[1], in: mesh))
                guard known.contains(key) else {
                    throw RecipeError(message: "no edge between vertex indices \(pair[0]) and \(pair[1])")
                }
                out.insert(key)
            }
            return .edges(out)
        }

        // Face sources, with optional `within` refinement.
        var faces: Set<FaceID>
        if selector.all == true {
            faces = Set(mesh.faceOrder)
        } else if let indices = selector.faces {
            faces = Set(try indices.map { try faceID(at: $0, in: mesh) })
        } else if let direction = selector.facing {
            guard direction.count == 3 else {
                throw RecipeError(message: "'facing' must be [x, y, z]")
            }
            let raw = SIMD3(direction[0], direction[1], direction[2])
            guard simd_length(raw) > MeshInvariants.epsilon else {
                throw RecipeError(message: "'facing' direction is zero-length")
            }
            let dir = simd_normalize(raw)
            let minDot = selector.minDot ?? 0.9
            faces = Set(mesh.faceOrder.filter { f in
                simd_dot(simd_normalize(mesh.faceNormalArea(f)), dir) >= minDot
            })
        } else if selector.within != nil {
            faces = Set(mesh.faceOrder)
        } else {
            // coverage:disable — unreachable today: the sources==1 guard means
            // one of the face branches above always matches by the time we get
            // here. Kept as a backstop for future selector sources.
            throw RecipeError(message: "selector selected nothing")
        }

        if let bounds = selector.within {
            guard bounds.min.count == 3, bounds.max.count == 3 else {
                throw RecipeError(message: "'within' needs min/max as [x, y, z]")
            }
            let lo = SIMD3(bounds.min[0], bounds.min[1], bounds.min[2])
            let hi = SIMD3(bounds.max[0], bounds.max[1], bounds.max[2])
            faces = faces.filter { f in
                let c = mesh.faceCentroid(f)
                return c.x >= lo.x && c.y >= lo.y && c.z >= lo.z
                    && c.x <= hi.x && c.y <= hi.y && c.z <= hi.z
            }
        }
        guard !faces.isEmpty else {
            throw RecipeError(message: "selector matched no faces — check 'facing'/'minDot'/'within' against the current geometry")
        }
        _ = defaultKind
        return .faces(faces)
    }

    // MARK: - Index mapping

    static func vertexID(at index: Int, in mesh: HalfEdgeMesh) throws -> VertexID {
        guard index >= 0, index < mesh.vertexOrder.count else {
            throw RecipeError(message: "vertex index \(index) out of range (mesh has \(mesh.vertexOrder.count) vertices)")
        }
        return mesh.vertexOrder[index]
    }

    static func faceID(at index: Int, in mesh: HalfEdgeMesh) throws -> FaceID {
        guard index >= 0, index < mesh.faceOrder.count else {
            throw RecipeError(message: "face index \(index) out of range (mesh has \(mesh.faceOrder.count) faces)")
        }
        return mesh.faceOrder[index]
    }

    private static func kindName(_ selection: ComponentSelection) -> String {
        switch selection {
        case .vertices: return "vertices"
        case .edges: return "edges"
        case .faces: return "faces"
        }
    }
}
