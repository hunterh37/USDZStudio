import Foundation
import EditingKit
import USDCore

/// Tiny JSON-Schema builders so tool contracts stay readable.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
    static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }
    static func number(_ description: String) -> JSONValue {
        .object(["type": "number", "description": .string(description)])
    }
    static func integer(_ description: String) -> JSONValue {
        .object(["type": "integer", "description": .string(description)])
    }
    static func boolean(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }
    static func array(of items: JSONValue, _ description: String) -> JSONValue {
        .object(["type": "array", "items": items, "description": .string(description)])
    }
    static let primRef = Schema.string("prim path (\"/A/B\") or session primId (\"prim-3\")")
    static let vec3 = Schema.array(of: .object(["type": "number"]), "[x, y, z]")
}

/// §3.1 Read tools — no mutation, cheap, typed hierarchy over screenshots.
public enum ReadTools {

    public static func register(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "query_scene", group: .read,
            description: "List prims as a typed hierarchy: path, primId, type, active, world bbox. Optional name/type filters.",
            inputSchema: Schema.object([
                "name": Schema.string("exact prim name filter"),
                "type": Schema.string("prim type filter, e.g. Mesh, Xform, Material"),
            ])
        ) { args in
            var prims = session.stage.allPrims()
            if let name = args["name"].stringValue { prims = prims.filter { $0.name == name } }
            if let type = args["type"].stringValue { prims = prims.filter { $0.typeName == type } }
            return .object([
                "prims": .array(prims.map { summary(of: $0, session: session) }),
                "count": .number(Double(prims.count)),
            ])
        })

        server.register(MCPTool(
            name: "get_prim", group: .read,
            description: "Full detail for one prim: attributes, relationships, variant sets, children, local+world transform.",
            inputSchema: Schema.object(["path": Schema.primRef], required: ["path"])
        ) { args in
            let prim = try session.requirePrim(args)
            return detail(of: prim, session: session)
        })

        server.register(MCPTool(
            name: "scene_stats", group: .read,
            description: "Whole-stage counts and bounds: prims, meshes, triangles, vertices, materials, up axis, metersPerUnit.",
            inputSchema: Schema.object([:])
        ) { _ in
            stats(session: session)
        })

        server.register(MCPTool(
            name: "list_variants", group: .read,
            description: "Variant sets and current selections on a prim.",
            inputSchema: Schema.object(["path": Schema.primRef], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            let sets = session.stage.prim(at: path)?.variantSets ?? []
            return .object([
                "variantSets": .array(sets.map { set in
                    .object([
                        "name": .string(set.name),
                        "variants": .array(set.variants.map { .string($0) }),
                        "selection": set.selection.map { .string($0) } ?? .null,
                    ])
                })
            ])
        })

        server.register(MCPTool(
            name: "describe_scene", group: .read,
            description: "One-call compact snapshot to (re)orient an agent: hierarchy outline, stats, bounds, material bindings, undo depth. Token-budgeted.",
            inputSchema: Schema.object([
                "maxDepth": Schema.integer("outline depth limit (default 4)")
            ])
        ) { args in
            describe(session: session, maxDepth: args["maxDepth"].intValue ?? 4)
        })
    }

    // MARK: - Payload builders (shared with MCP resources)

    static func summary(of prim: Prim, session: EditSession) -> JSONValue {
        var payload: [String: JSONValue] = [
            "path": .string(prim.path.description),
            "primId": .string(session.id(for: prim.path)),
            "type": .string(prim.typeName),
            "active": .bool(prim.isActive),
            "children": .number(Double(prim.children.count)),
        ]
        if let box = GeometryProbe.worldBBox(of: prim.path, in: session.stage) {
            payload["bbox"] = box.asJSON
            // Explicit space label (issue #160): a world bbox centred at the
            // origin otherwise reads exactly like a local-space/placement bug.
            payload["bboxSpace"] = .string("world")
        }
        if let binding = prim.relationships.first(where: { $0.name == "material:binding" }),
           let target = binding.targets.first {
            payload["material"] = .string(target.description)
        }
        return .object(payload)
    }

    static func detail(of prim: Prim, session: EditSession) -> JSONValue {
        let stage = session.stage
        return .object([
            "path": .string(prim.path.description),
            "primId": .string(session.id(for: prim.path)),
            "type": .string(prim.typeName),
            "active": .bool(prim.isActive),
            "visibility": .string(prim.visibility.rawValue),
            "attributes": .array(prim.attributes.map { attr in
                .object([
                    "name": .string(attr.name),
                    "type": .string(attr.value.typeLabel),
                    "value": attributeJSON(attr.value),
                    "animated": .bool(attr.isAnimated),
                ])
            }),
            "relationships": .array(prim.relationships.map { rel in
                .object([
                    "name": .string(rel.name),
                    "targets": .array(rel.targets.map { .string($0.description) }),
                ])
            }),
            "variantSets": .array(prim.variantSets.map { .string($0.name) }),
            "children": .array(prim.children.map { .string($0.path.description) }),
            "localTransform": trsJSON(stage.transform(at: prim.path)),
            "worldMatrix": .array(stage.worldMatrix(at: prim.path).map { .number($0) }),
        ])
    }

    static func stats(session: EditSession) -> JSONValue {
        let stage = session.stage
        let prims = stage.allPrims()
        var meshes = 0, triangles = 0, vertices = 0, materials = 0
        for prim in prims {
            if prim.typeName == "Material" { materials += 1 }
            guard case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value
            else { continue }
            meshes += 1
            triangles += counts.reduce(0) { $0 + max(0, $1 - 2) }
            if case .float3Array(let pts)? = prim.attribute(named: "points")?.value {
                vertices += pts.count / 3
            }
        }
        var payload: [String: JSONValue] = [
            "prims": .number(Double(prims.count)),
            "meshes": .number(Double(meshes)),
            "triangles": .number(Double(triangles)),
            "vertices": .number(Double(vertices)),
            "materials": .number(Double(materials)),
            "upAxis": .string(stage.metadata.upAxis.rawValue),
            "metersPerUnit": .number(stage.metadata.metersPerUnit),
        ]
        if let root = stage.rootPrims.first,
           let box = GeometryProbe.worldBBox(of: root.path, in: stage) {
            var whole = box
            for other in stage.rootPrims.dropFirst() {
                if let b = GeometryProbe.worldBBox(of: other.path, in: stage) { whole = whole.union(b) }
            }
            payload["bounds"] = whole.asJSON
        }
        return .object(payload)
    }

    static func describe(session: EditSession, maxDepth: Int) -> JSONValue {
        func outline(_ prim: Prim, depth: Int) -> JSONValue {
            var payload: [String: JSONValue] = [
                "path": .string(prim.path.description),
                "type": .string(prim.typeName),
            ]
            if !prim.isActive { payload["active"] = .bool(false) }
            if let binding = prim.relationships.first(where: { $0.name == "material:binding" }),
               let target = binding.targets.first {
                payload["material"] = .string(target.description)
            }
            if depth < maxDepth, !prim.children.isEmpty {
                payload["children"] = .array(prim.children.map { outline($0, depth: depth + 1) })
            } else if !prim.children.isEmpty {
                payload["childrenElided"] = .number(Double(prim.children.count))
            }
            return .object(payload)
        }
        return .object([
            "hierarchy": .array(session.stage.rootPrims.map { outline($0, depth: 1) }),
            "stats": stats(session: session),
            "undoDepth": .number(Double(session.stack.undoCount)),
            "canUndo": .bool(session.stack.canUndo),
            "strictness": .string(session.strictness.rawValue),
        ])
    }

    static func attributeJSON(_ value: AttributeValue) -> JSONValue {
        switch value {
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s), .token(let s), .asset(let s): return .string(s)
        case .vector(let v), .matrix4(let v), .doubleArray(let v),
             .float3Array(let v), .quatfArray(let v), .matrix4dArray(let v):
            return summarizeNumbers(v)
        case .intArray(let v): return summarizeNumbers(v.map(Double.init))
        case .stringArray(let v), .tokenArray(let v):
            return .array(v.map { .string($0) })
        case .unsupported(let typeName):
            return .object(["unsupported": .string(typeName)])
        }
    }

    /// Big numeric arrays are elided to a count + preview (token budget).
    private static func summarizeNumbers(_ values: [Double]) -> JSONValue {
        if values.count <= 16 { return .array(values.map { .number($0) }) }
        return .object([
            "count": .number(Double(values.count)),
            "preview": .array(values.prefix(6).map { .number($0) }),
        ])
    }

    static func trsJSON(_ trs: TRS) -> JSONValue {
        .object([
            "translation": .array(trs.translation.map { .number($0) }),
            "rotationEulerDegrees": .array(trs.rotationEulerDegrees.map { .number($0) }),
            "scale": .array(trs.scale.map { .number($0) }),
        ])
    }
}
