import Foundation

/// Typed recipe failures with the part/step coordinates an agent needs to fix
/// its JSON without guessing.
public struct RecipeError: Error, Equatable, CustomStringConvertible {
    public var part: String?
    /// 0-based step index within the part, nil for part-level failures.
    public var step: Int?
    public var message: String

    public init(part: String? = nil, step: Int? = nil, message: String) {
        self.part = part
        self.step = step
        self.message = message
    }

    public var description: String {
        var location = part.map { "part '\($0)'" } ?? "recipe"
        if let step { location += " step \(step)" }
        return "\(location): \(message)"
    }
}

/// Per-step machine-readable feedback: what ran, on how many components, and
/// the exact topology delta — the agent's "did that do what I predicted" signal.
public struct RecipeStepReport: Codable, Equatable, Sendable {
    public var index: Int
    public var op: String
    public var selectedComponents: Int
    public var deltaVertices: Int
    public var deltaEdges: Int
    public var deltaFaces: Int
}

public struct BuiltPart: Sendable {
    public var name: String
    public var mesh: HalfEdgeMesh
    public var flat: FlatMesh
    public var transform: RecipeTransform?
    public var material: String?
    public var stepReports: [RecipeStepReport]
}

public struct RecipeBuildResult: Sendable {
    public var recipe: ModelRecipe
    public var parts: [BuiltPart]

    public var totalVertices: Int { parts.reduce(0) { $0 + $1.mesh.vertexCount } }
    public var totalFaces: Int { parts.reduce(0) { $0 + $1.mesh.faceCount } }
    public var totalTriangles: Int {
        parts.reduce(0) { sum, part in
            sum + part.flat.faceVertexCounts.reduce(0) { $0 + max(0, $1 - 2) }
        }
    }
}

/// Executes a `ModelRecipe`: primitive → op chain per part, invariants
/// enforced after every op (via each op's own `OpSupport.verify`), plus a
/// final closed-form health check per part.
public enum RecipeEngine {

    public static func decode(_ data: Data) throws -> ModelRecipe {
        do {
            return try JSONDecoder().decode(ModelRecipe.self, from: data)
        } catch let error as DecodingError {
            throw RecipeError(message: "invalid recipe JSON — \(describe(error))")
        }
    }

    public static func execute(_ recipe: ModelRecipe) throws -> RecipeBuildResult {
        guard !recipe.name.isEmpty else { throw RecipeError(message: "recipe needs a name") }
        guard !recipe.parts.isEmpty else { throw RecipeError(message: "recipe has no parts") }
        if let axis = recipe.upAxis, !["Y", "Z"].contains(axis) {
            throw RecipeError(message: "upAxis must be \"Y\" or \"Z\", got \"\(axis)\"")
        }
        if let mpu = recipe.metersPerUnit, mpu <= 0 {
            throw RecipeError(message: "metersPerUnit must be > 0")
        }

        let materialNames = Set((recipe.materials ?? []).map(\.name))
        var seenMaterials = Set<String>()
        for material in recipe.materials ?? [] {
            guard seenMaterials.insert(USDAWriter.sanitize(material.name)).inserted else {
                throw RecipeError(message: "duplicate material name '\(material.name)' (after USD sanitizing)")
            }
            guard material.diffuseColor.count == 3,
                  material.diffuseColor.allSatisfy({ (0...1).contains($0) }) else {
                throw RecipeError(message: "material '\(material.name)' diffuseColor must be 3 values in 0…1")
            }
        }
        var seenParts = Set<String>()
        var parts: [BuiltPart] = []
        for part in recipe.parts {
            guard !part.name.isEmpty else { throw RecipeError(message: "every part needs a name") }
            guard seenParts.insert(USDAWriter.sanitize(part.name)).inserted else {
                throw RecipeError(message: "duplicate part name '\(part.name)' (after USD sanitizing)")
            }
            if let material = part.material, !materialNames.contains(material) {
                throw RecipeError(part: part.name,
                                  message: "unknown material '\(material)' (declared: \(materialNames.sorted().joined(separator: ", ")))")
            }
            parts.append(try build(part, materials: materialNames))
        }
        return RecipeBuildResult(recipe: recipe, parts: parts)
    }

    // MARK: - Part execution

    static func build(_ part: RecipePart, materials: Set<String>) throws -> BuiltPart {
        var mesh = try makePrimitive(part.primitive, part: part.name)
        var lastSelection: ComponentSelection?
        var reports: [RecipeStepReport] = []

        for (index, step) in (part.steps ?? []).enumerated() {
            do {
                let (next, result) = try apply(step, to: mesh, last: lastSelection,
                                               materials: materials,
                                               part: part.name, index: index)
                mesh = next
                lastSelection = result.resultSelection
                reports.append(RecipeStepReport(
                    index: index, op: step.op,
                    selectedComponents: count(of: result.appliedSelection),
                    deltaVertices: result.delta.vertices,
                    deltaEdges: result.delta.edges,
                    deltaFaces: result.delta.faces))
            } catch let error as MeshOpError {
                throw RecipeError(part: part.name, step: index, message: error.description)
            } catch let error as RecipeError {
                throw RecipeError(part: part.name, step: index, message: error.message)
            }
        }

        if let violation = MeshInvariants.violations(in: mesh).first {
            // coverage:disable — unreachable today: every mutating op runs
            // OpSupport.verify and subset tagging can't break invariants. Kept
            // as a hard backstop for future ops that bypass per-op verification.
            throw RecipeError(part: part.name, message: "final mesh unhealthy — \(violation)")
        }
        return BuiltPart(name: part.name, mesh: mesh, flat: MeshIO.flat(from: mesh),
                         transform: part.transform, material: part.material,
                         stepReports: reports)
    }

    struct StepResult {
        var resultSelection: ComponentSelection?
        var appliedSelection: ComponentSelection?
        var delta: TopologyDelta
    }

    static func apply(_ step: RecipeStep, to mesh: HalfEdgeMesh,
                      last: ComponentSelection?, materials: Set<String>,
                      part: String, index: Int) throws -> (HalfEdgeMesh, StepResult) {

        func fail(_ message: String) -> RecipeError {
            RecipeError(part: part, step: index, message: message)
        }
        func opResult(_ r: MeshOpResult, applied: ComponentSelection) -> (HalfEdgeMesh, StepResult) {
            (r.mesh, StepResult(resultSelection: r.resultSelection,
                                appliedSelection: applied, delta: r.delta))
        }

        switch step.op {
        case "extrude":
            guard let distance = step.distance else { throw fail("extrude requires 'distance'") }
            let selection = try SelectorResolver.faces(step.select, in: mesh, last: last)
            var direction = ExtrudeFaces.Params.Direction.averagedNormal
            if let axis = step.direction {
                direction = .axis(try vector3(axis, name: "direction", fail: fail))
            }
            let r = try ExtrudeFaces.apply(mesh, selection: selection,
                                           params: .init(distance: distance, direction: direction))
            return opResult(r, applied: selection)

        case "inset":
            guard let fraction = step.fraction else { throw fail("inset requires 'fraction'") }
            let selection = try SelectorResolver.faces(step.select, in: mesh, last: last)
            let r = try InsetFaces.apply(mesh, selection: selection, params: .init(fraction: fraction))
            return opResult(r, applied: selection)

        case "bevel":
            guard let width = step.width else { throw fail("bevel requires 'width'") }
            let selection = try SelectorResolver.edges(step.select, in: mesh, last: last)
            let r = try BevelEdges.apply(mesh, selection: selection, params: .init(width: width))
            return opResult(r, applied: selection)

        case "translate", "rotate", "scale", "transform":
            let params = try transformParams(step, fail: fail)
            let selection = try SelectorResolver.any(step.select, in: mesh, last: last)
            let r = try TransformComponents.apply(mesh, selection: selection, params: params)
            return opResult(r, applied: selection)

        case "merge":
            let selection = try SelectorResolver.vertices(step.select, in: mesh, last: last)
            let params: MergeVertices.Params
            switch (step.threshold, step.targetVertex) {
            case (let t?, nil): params = .byDistance(t)
            case (nil, let target?):
                params = .toVertex(try SelectorResolver.vertexID(at: target, in: mesh))
            case (nil, nil): throw fail("merge requires 'threshold' or 'targetVertex'")
            case (_?, _?): throw fail("merge takes 'threshold' or 'targetVertex', not both")
            }
            let r = try MergeVertices.apply(mesh, selection: selection, params: params)
            return opResult(r, applied: selection)

        case "delete":
            let selection = try SelectorResolver.any(step.select, in: mesh, last: last)
            let r = try DeleteComponents.apply(mesh, selection: selection)
            return opResult(r, applied: selection)

        case "fillHole":
            let selection = try SelectorResolver.edges(step.select, in: mesh, last: last)
            let r = try FillHole.apply(mesh, selection: selection, params: .init())
            return opResult(r, applied: selection)

        case "assignMaterial", "tagSubset":
            let subsetName: String
            if step.op == "assignMaterial" {
                guard let material = step.material else { throw fail("assignMaterial requires 'material'") }
                guard materials.contains(material) else {
                    throw fail("unknown material '\(material)' (declared: \(materials.sorted().joined(separator: ", ")))")
                }
                subsetName = material
            } else {
                guard let subset = step.subset, !subset.isEmpty else {
                    throw fail("tagSubset requires 'subset'")
                }
                subsetName = subset
            }
            let selection = try SelectorResolver.faces(step.select, in: mesh, last: last)
            guard case .faces(let faces) = selection else { throw fail("subset tagging needs faces") }
            var out = mesh
            for f in faces.sorted() { out.addFaceToSubset(f, subset: subsetName) }
            return (out, StepResult(resultSelection: selection, appliedSelection: selection,
                                    delta: TopologyDelta(vertices: 0, edges: 0, faces: 0)))

        default:
            throw fail("unknown op '\(step.op)' (known: extrude, inset, bevel, translate, rotate, scale, transform, merge, delete, fillHole, assignMaterial, tagSubset)")
        }
    }

    // MARK: - Helpers

    static func transformParams(_ step: RecipeStep,
                                fail: (String) -> RecipeError) throws -> TransformComponents.Params {
        var params = TransformComponents.Params()
        switch step.op {
        case "translate":
            guard let offset = step.offset else { throw fail("translate requires 'offset'") }
            params.translation = try vector3(offset, name: "offset", fail: fail)
        case "rotate":
            guard let degrees = step.rotateDegrees else { throw fail("rotate requires 'rotateDegrees'") }
            params.rotationDegrees = try vector3(degrees, name: "rotateDegrees", fail: fail)
        case "scale":
            guard let factors = step.scale else { throw fail("scale requires 'scale'") }
            params.scale = try vector3(factors, name: "scale", fail: fail)
        default: // "transform": any combination
            if let offset = step.offset { params.translation = try vector3(offset, name: "offset", fail: fail) }
            if let degrees = step.rotateDegrees { params.rotationDegrees = try vector3(degrees, name: "rotateDegrees", fail: fail) }
            if let factors = step.scale { params.scale = try vector3(factors, name: "scale", fail: fail) }
            if params.isIdentity {
                throw fail("transform requires at least one of 'offset', 'rotateDegrees', 'scale'")
            }
        }
        switch step.pivot {
        case nil: break
        case .keyword("selectionCentroid"): params.pivot = .selectionCentroid
        case .keyword("origin"): params.pivot = .origin
        case .keyword(let other):
            throw fail("unknown pivot '\(other)' (use \"selectionCentroid\", \"origin\", or [x, y, z])")
        case .point(let p):
            params.pivot = .point(try vector3(p, name: "pivot", fail: fail))
        }
        return params
    }

    static func makePrimitive(_ spec: RecipePrimitive, part: String) throws -> HalfEdgeMesh {
        func fail(_ message: String) -> RecipeError { RecipeError(part: part, message: message) }
        do {
            switch spec.type {
            case "box":
                let size = try sized(spec.size, count: 3, default: [1, 1, 1],
                                     name: "size", fail: fail)
                let segments = try sizedInts(spec.segments, count: 3, default: [1, 1, 1],
                                             name: "segments", fail: fail)
                return try Primitives.box(width: size[0], height: size[1], depth: size[2],
                                          segments: SIMD3(segments[0], segments[1], segments[2]))
            case "plane":
                let size = try sized(spec.size, count: 2, default: [1, 1], name: "size", fail: fail)
                let segments = try sizedInts(spec.segments, count: 2, default: [1, 1],
                                             name: "segments", fail: fail)
                return try Primitives.plane(width: size[0], depth: size[1],
                                            segmentsX: segments[0], segmentsZ: segments[1])
            case "cylinder":
                return try Primitives.cylinder(radius: spec.radius ?? 0.5,
                                               height: spec.height ?? 1,
                                               radialSegments: spec.radialSegments ?? 8,
                                               heightSegments: spec.heightSegments ?? 1,
                                               capped: spec.capped ?? true)
            case "cone":
                return try Primitives.cone(radius: spec.radius ?? 0.5,
                                           height: spec.height ?? 1,
                                           radialSegments: spec.radialSegments ?? 8)
            case "sphere":
                return try Primitives.uvSphere(radius: spec.radius ?? 0.5,
                                               rings: spec.rings ?? 6,
                                               segments: spec.radialSegments ?? 8)
            default:
                throw fail("unknown primitive '\(spec.type)' (known: box, plane, cylinder, cone, sphere)")
            }
        } catch let error as MeshOpError {
            throw fail("primitive \(spec.type): \(error.description)")
        }
    }

    static func vector3(_ values: [Double], name: String,
                        fail: (String) -> RecipeError) throws -> SIMD3<Double> {
        guard values.count == 3 else { throw fail("'\(name)' must be [x, y, z]") }
        return SIMD3(values[0], values[1], values[2])
    }

    static func sized(_ values: [Double]?, count: Int, default def: [Double],
                      name: String, fail: (String) -> RecipeError) throws -> [Double] {
        guard let values else { return def }
        guard values.count == count else { throw fail("'\(name)' must have \(count) values") }
        return values
    }

    static func sizedInts(_ values: [Int]?, count: Int, default def: [Int],
                          name: String, fail: (String) -> RecipeError) throws -> [Int] {
        guard let values else { return def }
        guard values.count == count else { throw fail("'\(name)' must have \(count) values") }
        return values
    }

    static func count(of selection: ComponentSelection?) -> Int {
        switch selection {
        case nil: return 0
        case .vertices(let s): return s.count
        case .edges(let s): return s.count
        case .faces(let s): return s.count
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: ".")
            return joined.isEmpty ? "top level" : joined
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return String(describing: error)
        }
    }
}
