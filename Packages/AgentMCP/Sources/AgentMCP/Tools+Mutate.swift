import Foundation
import EditingKit
import MeshKit
import USDCore

/// §3.2 Mutate tools — every one maps to an `EditCommand` run through the
/// session's `CommandStack`: one undoable step, one synthesized diff, inline
/// validation per the session's strictness mode.
public enum MutateTools {

    public static func register(on server: MCPServer, session: EditSession) {
        registerStructural(on: server, session: session)
        registerAttributes(on: server, session: session)
        registerMesh(on: server, session: session)
        registerBatch(on: server, session: session)
    }

    // MARK: - Structural

    private static func registerStructural(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "create_prim", group: .mutate,
            description: "Create a prim (Xform, Scope, Mesh, …) under a parent. Returns the new prim's primId.",
            inputSchema: Schema.object([
                "parent": Schema.string("parent prim path/primId; omit for stage root"),
                "name": Schema.string("new prim name"),
                "type": Schema.string("prim type name (default Xform)"),
            ], required: ["name"])
        ) { args in
            let built = try makeInsert(args: args, session: session, extraAttributes: [])
            let outcome = try session.mutate(built.command)
            return outcome.asJSON(extra: ["path": .string(built.path.description)])
        })

        server.register(MCPTool(
            name: "create_mesh", group: .mutate,
            description: "Create a Mesh prim from a parametric primitive: plane, box, cylinder, cone, or sphere. Guaranteed manifold.",
            inputSchema: Schema.object([
                "parent": Schema.string("parent prim path/primId; omit for stage root"),
                "name": Schema.string("new prim name"),
                "shape": Schema.string("plane | box | cylinder | cone | sphere"),
                "width": Schema.number("box/plane width (default 1)"),
                "height": Schema.number("box/cylinder/cone height (default 1)"),
                "depth": Schema.number("box/plane depth (default 1)"),
                "radius": Schema.number("cylinder/cone/sphere radius (default 0.5)"),
                "segments": Schema.integer("radial/ring segments (default 8)"),
                "smooth": Schema.boolean("author as a Catmull-Clark subdivision surface instead of crisp polygons (default false)"),
            ], required: ["name", "shape"])
        ) { args in
            let mesh = try primitive(from: args)
            let flat = MeshIO.flat(from: mesh)
            // Default to crisp polygons; only subdivide when explicitly requested (#97).
            let scheme = (args["smooth"].boolValue ?? false) ? "catmullClark" : "none"
            let built = try makeInsert(
                args: args, session: session,
                extraAttributes: GeometryProbe.meshAttributes(from: flat, subdivisionScheme: scheme),
                typeOverride: "Mesh")
            let outcome = try session.mutate(built.command)
            return outcome.asJSON(extra: ["path": .string(built.path.description)])
        })

        server.register(MCPTool(
            name: "remove_prim", group: .mutate,
            description: "Delete a prim subtree. Its primIds become permanently invalid.",
            inputSchema: Schema.object(["path": Schema.primRef], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            let command = try removeCommand(for: path, session: session)
            return try session.mutate(command, removed: [path]).asJSON()
        })

        server.register(MCPTool(
            name: "rename_prim", group: .mutate,
            description: "Rename a prim. primIds keep tracking the renamed subtree; old paths go stale.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "name": Schema.string("new prim name (USD identifier)"),
            ], required: ["path", "name"])
        ) { args in
            let path = try session.resolve(args)
            guard let name = args["name"].stringValue, PrimPath.isValidName(name) else {
                throw ToolError.invalidParams("'name' must be a valid USD identifier")
            }
            let command = RenamePrimCommand(path: path, newName: name)
            return try session.mutate(command, moved: [(path, command.renamedPath)]).asJSON()
        })

        server.register(MCPTool(
            name: "reparent_prim", group: .mutate,
            description: "Move a prim under a new parent. primIds keep tracking the moved subtree.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "newParent": Schema.string("new parent path/primId; omit for stage root"),
            ], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            let parent: PrimPath? = args["newParent"].isNull
                ? nil : try session.resolve(args, key: "newParent")
            guard let command = ReparentPrimCommand.make(path: path, under: parent, in: session.stage) else {
                throw ToolError.invalidParams(
                    "cannot reparent \(path) under \(parent?.description ?? "/") (cycle, collision, or missing prim)")
            }
            let newPath = (parent ?? .root).appending(path.name) ?? path
            return try session.mutate(command, moved: [(path, newPath)]).asJSON()
        })

        server.register(MCPTool(
            name: "duplicate_prim", group: .mutate,
            description: "Duplicate a prim subtree as a sibling. Returns the duplicate's path and primId.",
            inputSchema: Schema.object(["path": Schema.primRef], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            guard let command = DuplicatePrimCommand.make(path: path, in: session.stage) else {
                // coverage:disable — make() returns nil only for missing/root prims, which resolve() already rejects.
                throw ToolError.invalidParams("cannot duplicate \(path)")
                // coverage:enable
            }
            let outcome = try session.mutate(command)
            return outcome.asJSON(extra: ["path": .string(command.duplicatePath.description)])
        })

        server.register(MCPTool(
            name: "group_prims", group: .mutate,
            description: "Group sibling prims under a new Xform. Returns the group's path.",
            inputSchema: Schema.object([
                "paths": Schema.array(of: Schema.primRef, "prims to group (siblings)"),
                "name": Schema.string("group name (default 'Group')"),
            ], required: ["paths"])
        ) { args in
            guard let rawPaths = args["paths"].arrayValue, !rawPaths.isEmpty else {
                throw ToolError.invalidParams("'paths' must be a non-empty array")
            }
            var paths: [PrimPath] = []
            for raw in rawPaths {
                paths.append(try session.resolve(.object(["path": raw])))
            }
            let name = args["name"].stringValue ?? "Group"
            guard let command = GroupPrimsCommand.make(paths: paths, named: name, in: session.stage) else {
                throw ToolError.invalidParams("cannot group \(paths.map(\.description).joined(separator: ", ")) — prims must share a parent")
            }
            let moved = paths.compactMap { p in
                command.groupPath.appending(p.name).map { (from: p, to: $0) }
            }
            let outcome = try session.mutate(command, moved: moved)
            return outcome.asJSON(extra: ["path": .string(command.groupPath.description)])
        })

        server.register(MCPTool(
            name: "set_active", group: .mutate,
            description: "Activate or deactivate a prim.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "active": Schema.boolean("desired activation state"),
            ], required: ["path", "active"])
        ) { args in
            let path = try session.resolve(args)
            guard let active = args["active"].boolValue else {
                throw ToolError.invalidParams("'active' must be a boolean")
            }
            let old = session.stage.prim(at: path)?.isActive ?? true
            let command = SetActiveCommand(path: path, newValue: active, oldValue: old)
            return try session.mutate(command).asJSON()
        })

        server.register(MCPTool(
            name: "set_variant", group: .mutate,
            description: "Select a variant in a prim's variant set (null selection clears it).",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "set": Schema.string("variant set name"),
                "selection": Schema.string("variant to select, or null to clear"),
            ], required: ["path", "set"])
        ) { args in
            let path = try session.resolve(args)
            guard let setName = args["set"].stringValue else {
                throw ToolError.invalidParams("missing 'set'")
            }
            guard let variantSet = session.stage.prim(at: path)?.variantSets
                .first(where: { $0.name == setName })
            else {
                throw ToolError.invalidParams("prim \(path) has no variant set '\(setName)'")
            }
            let selection = args["selection"].stringValue
            if let selection, !variantSet.variants.contains(selection) {
                throw ToolError.invalidParams(
                    "'\(selection)' is not in set '\(setName)' (\(variantSet.variants.joined(separator: ", ")))")
            }
            let command = SetVariantSelectionCommand(
                path: path, setName: setName,
                newSelection: selection, oldSelection: variantSet.selection)
            return try session.mutate(command).asJSON()
        })

        server.register(MCPTool(
            name: "create_material", group: .mutate,
            description: "Create a UsdPreviewSurface material and bind it to a target prim.",
            inputSchema: Schema.object([
                "target": Schema.primRef,
                "baseColor": Schema.array(of: .object(["type": "number"]), "[r, g, b] in 0–1 (default 0.18 grey)"),
            ], required: ["target"])
        ) { args in
            let target = try session.resolve(args, key: "target")
            let color = args["baseColor"].doubleArrayValue ?? [0.18, 0.18, 0.18]
            guard color.count == 3, color.allSatisfy({ $0 >= 0 && $0 <= 1 }) else {
                throw ToolError.invalidParams("'baseColor' must be [r, g, b] with components in 0...1")
            }
            guard let command = CreateMaterialCommand.make(
                bindingTo: target, baseColor: color, in: session.stage)
            else {
                // coverage:disable — make() returns nil only when the target prim is missing, which resolve() already rejects.
                throw ToolError.invalidParams("cannot create material bound to \(target)")
                // coverage:enable
            }
            let outcome = try session.mutate(command)
            return outcome.asJSON(extra: ["materialPath": .string(command.materialPath.description)])
        })
    }

    // MARK: - Attributes & transform

    private static func registerAttributes(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "set_attribute", group: .mutate,
            description: "Set (or author) a typed attribute on a prim.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "name": Schema.string("attribute name, e.g. 'points' or 'primvars:displayColor'"),
                "type": Schema.string("bool | int | double | string | token | asset | vector | matrix4 | intArray | doubleArray | stringArray | tokenArray | float3Array"),
                "value": .object(["description": "attribute value matching 'type'"]),
            ], required: ["path", "name", "type", "value"])
        ) { args in
            let path = try session.resolve(args)
            guard let name = args["name"].stringValue, !name.isEmpty else {
                throw ToolError.invalidParams("missing 'name'")
            }
            let value = try attributeValue(type: args["type"].stringValue ?? "", json: args["value"])
            let old = session.stage.prim(at: path)?.attribute(named: name)
            let command = SetAttributeCommand(
                path: path,
                newAttribute: Attribute(name: name, value: value),
                oldAttribute: old)
            return try session.mutate(command).asJSON()
        })

        server.register(MCPTool(
            name: "remove_attribute", group: .mutate,
            description: "Remove an authored attribute from a prim.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "name": Schema.string("attribute name"),
            ], required: ["path", "name"])
        ) { args in
            let path = try session.resolve(args)
            guard let name = args["name"].stringValue,
                  let command = RemoveAttributeCommand.make(path: path, name: name, in: session.stage)
            else {
                throw ToolError.invalidParams("prim \(try session.resolve(args)) has no attribute '\(args["name"].stringValue ?? "?")'")
            }
            return try session.mutate(command).asJSON()
        })

        server.register(MCPTool(
            name: "set_transform", group: .mutate,
            description: "Set a prim's local TRS, or place it declaratively with relativeTo: { anchor, rule: on_top|below|left_of|right_of|in_front_of|behind|inside_center, align: center|keep, gap } — resolved deterministically from world bboxes.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "translation": Schema.vec3,
                "rotationEulerDegrees": Schema.vec3,
                "scale": Schema.vec3,
                "relativeTo": Schema.object([
                    "anchor": Schema.primRef,
                    "rule": Schema.string("spatial rule"),
                    "align": Schema.string("center (default) | keep"),
                    "gap": Schema.number("clearance in scene units (default 0)"),
                ], required: ["anchor", "rule"]),
            ], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            let old = session.stage.prim(at: path)?.attribute(named: transformAttributeName)

            let newTRS: TRS
            if !args["relativeTo"].isNull {
                let constraint = try SpatialSolver.constraint(from: args["relativeTo"], session: session)
                guard constraint.anchor != path, !constraint.anchor.isDescendant(of: path) else {
                    throw ToolError.invalidParams("anchor must not be the subject or inside it")
                }
                newTRS = try SpatialSolver.solve(subject: path, constraint: constraint, stage: session.stage)
            } else {
                var trs = session.stage.transform(at: path)
                if let t = args["translation"].doubleArrayValue {
                    guard t.count == 3 else { throw ToolError.invalidParams("'translation' must be [x, y, z]") }
                    trs.translation = t
                }
                if let r = args["rotationEulerDegrees"].doubleArrayValue {
                    guard r.count == 3 else { throw ToolError.invalidParams("'rotationEulerDegrees' must be [x, y, z]") }
                    trs.rotationEulerDegrees = r
                }
                if let s = args["scale"].doubleArrayValue {
                    guard s.count == 3, s.allSatisfy({ $0 != 0 }) else {
                        throw ToolError.invalidParams("'scale' must be [x, y, z], no zero components")
                    }
                    trs.scale = s
                }
                newTRS = trs
            }

            let command = SetTransformCommand(path: path, newTRS: newTRS, oldAttribute: old)
            let outcome = try session.mutate(command)
            return outcome.asJSON(extra: ["transform": ReadTools.trsJSON(newTRS)])
        })
    }

    // MARK: - Mesh editing

    private static func registerMesh(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "edit_mesh", group: .mutate,
            description: "Apply a chain of topology ops to a Mesh prim in one undoable step. Ops: extrude_faces {faces, distance}, inset_faces {faces, fraction}, delete_faces {faces}, mirror {axis, coordinate}, solidify {thickness}. mirror/solidify are whole-mesh (they act on every face; 'faces' is ignored). Omitted 'faces' reuses the previous op's result selection. Returns per-op topology deltas.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "ops": Schema.array(of: Schema.object([
                    "op": Schema.string("extrude_faces | inset_faces | delete_faces | mirror | solidify"),
                    "faces": Schema.array(of: .object(["type": "integer"]), "face ids"),
                    "distance": Schema.number("extrude distance"),
                    "fraction": Schema.number("inset fraction (0–1)"),
                    "axis": Schema.string("mirror plane axis: x | y | z"),
                    "coordinate": Schema.number("mirror plane coordinate along axis (default 0)"),
                    "thickness": Schema.number("solidify shell thickness (> 0)"),
                ], required: ["op"]), "ops applied in order"),
            ], required: ["path", "ops"])
        ) { args in
            let prim = try session.requirePrim(args)
            let path = prim.path
            guard let ops = args["ops"].arrayValue, !ops.isEmpty else {
                throw ToolError.invalidParams("'ops' must be a non-empty array")
            }
            let flat = try GeometryProbe.flatMesh(of: prim)
            var meshSession: MeshEditSession
            do {
                meshSession = try MeshEditSession(path: path, flat: flat)
            } catch {
                throw ToolError.unsupported("\(error)")
            }

            var deltas: [JSONValue] = []
            var carrySelection: ComponentSelection?
            for (index, opJSON) in ops.enumerated() {
                let selection: ComponentSelection
                // mirror/solidify are whole-mesh (#69): they act on every face,
                // so they never require a 'faces' arg or a carried selection.
                if opJSON["op"].stringValue == "mirror" || opJSON["op"].stringValue == "solidify" {
                    selection = .faces(Set(meshSession.mesh.faceOrder))
                } else if let faceInts = opJSON["faces"].intArrayValue {
                    selection = .faces(Set(faceInts.map(FaceID.init)))
                } else if let carry = carrySelection {
                    selection = carry
                } else {
                    throw ToolError.invalidParams("op[\(index)] needs 'faces' (no previous selection to reuse)")
                }
                let result: MeshOpResult
                do {
                    result = try apply(opJSON: opJSON, index: index,
                                       mesh: meshSession.mesh, selection: selection)
                } catch let error as MeshOpError {
                    throw ToolError.failed("op[\(index)] \(opJSON["op"].stringValue ?? "?"): \(error)")
                }
                meshSession.record(result, journalEntry: opJSON["op"].stringValue ?? "op")
                carrySelection = result.resultSelection
                deltas.append(.object([
                    "op": .string(opJSON["op"].stringValue ?? "?"),
                    "vertices": .number(Double(result.delta.vertices)),
                    "edges": .number(Double(result.delta.edges)),
                    "faces": .number(Double(result.delta.faces)),
                ]))
            }

            guard let command = meshSession.commitCommand() else {
                // coverage:disable — commitCommand() is nil only when nothing was recorded; every loop iteration records or throws, and ops is non-empty.
                throw ToolError.failed("mesh edit produced no change")
                // coverage:enable
            }
            let outcome = try session.mutate(command)
            return outcome.asJSON(extra: ["topologyDeltas": .array(deltas)])
        })
    }

    private static func apply(
        opJSON: JSONValue, index: Int, mesh: HalfEdgeMesh, selection: ComponentSelection
    ) throws -> MeshOpResult {
        switch opJSON["op"].stringValue {
        case "extrude_faces":
            guard let distance = opJSON["distance"].doubleValue else {
                throw ToolError.invalidParams("op[\(index)] extrude_faces needs 'distance'")
            }
            return try ExtrudeFaces.apply(
                mesh, selection: selection,
                params: ExtrudeFaces.Params(distance: distance))
        case "inset_faces":
            guard let fraction = opJSON["fraction"].doubleValue, fraction > 0, fraction < 1 else {
                throw ToolError.invalidParams("op[\(index)] inset_faces needs 'fraction' in (0, 1)")
            }
            return try InsetFaces.apply(
                mesh, selection: selection, params: InsetFaces.Params(fraction: fraction))
        case "delete_faces":
            return try DeleteComponents.apply(
                mesh, selection: selection, params: DeleteComponents.Params())
        case "mirror":
            // Whole-mesh: mirror every face across the chosen plane.
            let axis: Mirror.Axis
            switch opJSON["axis"].stringValue {
            case "x", nil: axis = .x
            case "y": axis = .y
            case "z": axis = .z
            default:
                throw ToolError.invalidParams("op[\(index)] mirror 'axis' must be x, y, or z")
            }
            let coordinate = opJSON["coordinate"].doubleValue ?? 0
            return try Mirror.apply(
                mesh, selection: .faces(Set(mesh.faceOrder)),
                params: Mirror.Params(axis: axis, coordinate: coordinate))
        case "solidify":
            // Whole-mesh: give the entire open surface thickness.
            guard let thickness = opJSON["thickness"].doubleValue, thickness > 0 else {
                throw ToolError.invalidParams("op[\(index)] solidify needs 'thickness' > 0")
            }
            return try Solidify.apply(
                mesh, selection: .faces(Set(mesh.faceOrder)),
                params: Solidify.Params(thickness: thickness))
        default:
            throw ToolError.invalidParams(
                "op[\(index)] unknown op '\(opJSON["op"].stringValue ?? "?")' (extrude_faces, inset_faces, delete_faces, mirror, solidify)")
        }
    }

    // MARK: - Batch (§3.2 `batch` → CompositeCommand)

    private static func registerBatch(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "batch", group: .mutate,
            description: "Run several simple mutations atomically as ONE undo step (CompositeCommand). Supported ops: set_attribute, set_active, remove_prim, rename_prim. Keeps individual calls small while transactions stay big.",
            inputSchema: Schema.object([
                "label": Schema.string("undo label for the whole batch"),
                "ops": Schema.array(of: Schema.object([
                    "tool": Schema.string("set_attribute | set_active | remove_prim | rename_prim"),
                    "args": .object(["description": "that tool's arguments"]),
                ], required: ["tool", "args"]), "mutations, applied in order"),
            ], required: ["ops"])
        ) { args in
            guard let ops = args["ops"].arrayValue, !ops.isEmpty else {
                throw ToolError.invalidParams("'ops' must be a non-empty array")
            }
            var commands: [any EditCommand] = []
            var moved: [(PrimPath, PrimPath)] = []
            var removed: [PrimPath] = []
            for (index, op) in ops.enumerated() {
                let sub = op["args"]
                switch op["tool"].stringValue {
                case "set_attribute":
                    let path = try session.resolve(sub)
                    guard let name = sub["name"].stringValue else {
                        throw ToolError.invalidParams("ops[\(index)]: missing 'name'")
                    }
                    let value = try attributeValue(type: sub["type"].stringValue ?? "", json: sub["value"])
                    commands.append(SetAttributeCommand(
                        path: path,
                        newAttribute: Attribute(name: name, value: value),
                        oldAttribute: session.stage.prim(at: path)?.attribute(named: name)))
                case "set_active":
                    let path = try session.resolve(sub)
                    guard let active = sub["active"].boolValue else {
                        throw ToolError.invalidParams("ops[\(index)]: missing 'active'")
                    }
                    commands.append(SetActiveCommand(
                        path: path, newValue: active,
                        oldValue: session.stage.prim(at: path)?.isActive ?? true))
                case "remove_prim":
                    let path = try session.resolve(sub)
                    commands.append(try removeCommand(for: path, session: session))
                    removed.append(path)
                case "rename_prim":
                    let path = try session.resolve(sub)
                    guard let name = sub["name"].stringValue, PrimPath.isValidName(name) else {
                        throw ToolError.invalidParams("ops[\(index)]: invalid 'name'")
                    }
                    let command = RenamePrimCommand(path: path, newName: name)
                    moved.append((path, command.renamedPath))
                    commands.append(command)
                default:
                    throw ToolError.invalidParams(
                        "ops[\(index)]: unsupported batch tool '\(op["tool"].stringValue ?? "?")'")
                }
            }
            let label = args["label"].stringValue ?? "Batch (\(commands.count) ops)"
            let composite = CompositeCommand(label: label, commands: commands)
            return try session.mutate(composite, moved: moved, removed: removed).asJSON()
        })
    }

    // MARK: - Shared factories

    struct BuiltInsert {
        var command: InsertPrimCommand
        var path: PrimPath
    }

    static func makeInsert(
        args: JSONValue, session: EditSession,
        extraAttributes: [Attribute], typeOverride: String? = nil
    ) throws -> BuiltInsert {
        let parent: PrimPath?
        let siblings: [Prim]
        if args["parent"].isNull {
            parent = nil
            siblings = session.stage.rootPrims
        } else {
            let parentPath = try session.resolve(args, key: "parent")
            parent = parentPath
            siblings = session.stage.prim(at: parentPath)?.children ?? []
        }
        let base = parent ?? .root
        guard let name = args["name"].stringValue, PrimPath.isValidName(name),
              let path = base.appending(name)
        else {
            throw ToolError.invalidParams("'name' must be a valid USD identifier")
        }
        guard !siblings.contains(where: { $0.name == name }) else {
            throw ToolError.invalidParams(
                "'\(name)' already exists under \(parent?.description ?? "/")")
        }
        let prim = Prim(
            path: path,
            typeName: typeOverride ?? args["type"].stringValue ?? "Xform",
            attributes: extraAttributes)
        return BuiltInsert(
            command: InsertPrimCommand(prim: prim, parent: parent, index: siblings.count),
            path: path)
    }

    static func removeCommand(for path: PrimPath, session: EditSession) throws -> RemovePrimCommand {
        guard let prim = session.stage.prim(at: path) else {
            // coverage:disable — both callers (remove_prim, batch) resolve() the path first, which guarantees existence.
            throw ToolError.primNotFound(path.description)
            // coverage:enable
        }
        let parent = path.depth > 1 ? path.parent : nil
        let siblings = parent.flatMap { session.stage.prim(at: $0)?.children } ?? session.stage.rootPrims
        let index = siblings.firstIndex(where: { $0.path == path }) ?? 0
        return RemovePrimCommand(prim: prim, parent: parent, index: index)
    }

    static func primitive(from args: JSONValue) throws -> HalfEdgeMesh {
        let width = args["width"].doubleValue ?? 1
        let height = args["height"].doubleValue ?? 1
        let depth = args["depth"].doubleValue ?? 1
        let radius = args["radius"].doubleValue ?? 0.5
        let segments = args["segments"].intValue ?? 8
        guard width > 0, height > 0, depth > 0, radius > 0, segments >= 3 else {
            throw ToolError.invalidParams("dimensions must be positive; segments >= 3")
        }
        do {
            switch args["shape"].stringValue {
            case "plane": return try Primitives.plane(width: width, depth: depth)
            case "box": return try Primitives.box(width: width, height: height, depth: depth)
            case "cylinder":
                return try Primitives.cylinder(radius: radius, height: height, radialSegments: segments)
            case "cone":
                return try Primitives.cone(radius: radius, height: height, radialSegments: segments)
            case "sphere":
                return try Primitives.uvSphere(radius: radius, rings: max(3, segments / 2), segments: segments)
            default:
                throw ToolError.invalidParams(
                    "unknown shape '\(args["shape"].stringValue ?? "?")' (plane, box, cylinder, cone, sphere)")
            }
        } catch let error as MeshOpError {
            // coverage:disable — Primitives throws only on degenerate parameters, all rejected by the range guard above; kept so a new primitive's failure surfaces structurally.
            throw ToolError.failed("primitive construction failed: \(error)")
            // coverage:enable
        }
    }

    /// Decode a typed attribute value (plan §3 pre-validation: enums must
    /// match, values must be in range — fail structured, before the stage).
    static func attributeValue(type: String, json: JSONValue) throws -> AttributeValue {
        func doubles(_ expected: Int? = nil) throws -> [Double] {
            guard let values = json.doubleArrayValue else {
                throw ToolError.invalidParams("value for '\(type)' must be a numeric array")
            }
            if let expected, values.count != expected {
                throw ToolError.invalidParams("value for '\(type)' must have \(expected) numbers")
            }
            return values
        }
        switch type {
        case "bool":
            guard let b = json.boolValue else { throw ToolError.invalidParams("value must be a boolean") }
            return .bool(b)
        case "int":
            guard let i = json.intValue else { throw ToolError.invalidParams("value must be an integer") }
            return .int(i)
        case "double":
            guard let d = json.doubleValue else { throw ToolError.invalidParams("value must be a number") }
            return .double(d)
        case "string":
            guard let s = json.stringValue else { throw ToolError.invalidParams("value must be a string") }
            return .string(s)
        case "token":
            guard let s = json.stringValue else { throw ToolError.invalidParams("value must be a string") }
            return .token(s)
        case "asset":
            guard let s = json.stringValue else { throw ToolError.invalidParams("value must be a string") }
            return .asset(s)
        case "vector": return .vector(try doubles(3))
        case "matrix4": return .matrix4(try doubles(16))
        case "doubleArray": return .doubleArray(try doubles())
        case "float3Array":
            let values = try doubles()
            guard values.count % 3 == 0 else {
                throw ToolError.invalidParams("float3Array length must be a multiple of 3")
            }
            return .float3Array(values)
        case "intArray":
            guard let ints = json.intArrayValue else {
                throw ToolError.invalidParams("value must be an integer array")
            }
            return .intArray(ints)
        case "stringArray":
            guard let strings = json.stringArrayValue else {
                throw ToolError.invalidParams("value must be a string array")
            }
            return .stringArray(strings)
        case "tokenArray":
            guard let strings = json.stringArrayValue else {
                throw ToolError.invalidParams("value must be a string array")
            }
            return .tokenArray(strings)
        default:
            throw ToolError.invalidParams("unknown attribute type '\(type)'")
        }
    }
}
