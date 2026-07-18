import Foundation

/// Declarative build recipe for agent-driven low-poly modeling: primitives +
/// an op chain per part + flat-color materials, executed by `RecipeEngine`
/// and exported by `USDAWriter`. Designed so a coding agent can emit JSON, get
/// machine-checkable feedback (typed errors, per-step topology deltas), render
/// the result, and iterate.
///
/// Schema notes:
/// - Op parameters are optional fields validated per-op by the engine so a
///   wrong recipe fails with "extrude requires 'distance'", not a decoding
///   trace.
/// - Component indices refer to the mesh state *at that step*, in export
///   order (`vertexOrder` / `faceOrder`) — the order `dump`/reports print.
public struct ModelRecipe: Codable, Equatable, Sendable {
    /// Model name → root prim / defaultPrim (sanitized for USD).
    public var name: String
    /// "Y" (default) or "Z".
    public var upAxis: String?
    /// Defaults to 1.
    public var metersPerUnit: Double?
    public var materials: [RecipeMaterial]?
    public var parts: [RecipePart]

    public init(name: String, upAxis: String? = nil, metersPerUnit: Double? = nil,
                materials: [RecipeMaterial]? = nil, parts: [RecipePart]) {
        self.name = name
        self.upAxis = upAxis
        self.metersPerUnit = metersPerUnit
        self.materials = materials
        self.parts = parts
    }
}

/// Flat PBR material authored as a UsdPreviewSurface shader child of the
/// Material prim (the real-file shape — see .claude/skills/verify).
public struct RecipeMaterial: Codable, Equatable, Sendable {
    public var name: String
    /// RGB in 0…1. Also authored as the mesh displayColor for viewers that
    /// ignore materials.
    public var diffuseColor: [Double]
    public var roughness: Double?
    public var metallic: Double?
    public var opacity: Double?

    public init(name: String, diffuseColor: [Double], roughness: Double? = nil,
                metallic: Double? = nil, opacity: Double? = nil) {
        self.name = name
        self.diffuseColor = diffuseColor
        self.roughness = roughness
        self.metallic = metallic
        self.opacity = opacity
    }
}

public struct RecipePart: Codable, Equatable, Sendable {
    public var name: String
    public var primitive: RecipePrimitive
    /// Authored as xformOps on the part's Xform (not baked into points).
    public var transform: RecipeTransform?
    /// Whole-part material binding (name from `materials`).
    public var material: String?
    public var steps: [RecipeStep]?

    public init(name: String, primitive: RecipePrimitive,
                transform: RecipeTransform? = nil, material: String? = nil,
                steps: [RecipeStep]? = nil) {
        self.name = name
        self.primitive = primitive
        self.transform = transform
        self.material = material
        self.steps = steps
    }
}

/// Primitive spec; `type` selects the generator, remaining fields are
/// per-type (validated by the engine, defaults documented in `Primitives`).
public struct RecipePrimitive: Codable, Equatable, Sendable {
    /// "box" | "plane" | "cylinder" | "cone" | "sphere"
    public var type: String
    /// box: [w, h, d]; plane: [w, d]
    public var size: [Double]?
    /// box: [sx, sy, sz]; plane: [sx, sz]
    public var segments: [Int]?
    public var radius: Double?
    public var height: Double?
    public var radialSegments: Int?
    public var heightSegments: Int?
    public var rings: Int?
    public var capped: Bool?

    public init(type: String, size: [Double]? = nil, segments: [Int]? = nil,
                radius: Double? = nil, height: Double? = nil,
                radialSegments: Int? = nil, heightSegments: Int? = nil,
                rings: Int? = nil, capped: Bool? = nil) {
        self.type = type
        self.size = size
        self.segments = segments
        self.radius = radius
        self.height = height
        self.radialSegments = radialSegments
        self.heightSegments = heightSegments
        self.rings = rings
        self.capped = capped
    }
}

public struct RecipeTransform: Codable, Equatable, Sendable {
    public var translate: [Double]?
    /// XYZ Euler, degrees.
    public var rotateDegrees: [Double]?
    public var scale: [Double]?

    public init(translate: [Double]? = nil, rotateDegrees: [Double]? = nil,
                scale: [Double]? = nil) {
        self.translate = translate
        self.rotateDegrees = rotateDegrees
        self.scale = scale
    }
}

/// One modeling step. `op` is one of: "extrude", "inset", "bevel", "translate",
/// "rotate", "scale", "transform", "merge", "delete", "fillHole",
/// "assignMaterial", "tagSubset".
public struct RecipeStep: Codable, Equatable, Sendable {
    public var op: String
    public var select: RecipeSelector?
    // extrude
    public var distance: Double?
    /// Explicit extrude axis; omitted → averaged region normal.
    public var direction: [Double]?
    // inset
    public var fraction: Double?
    // bevel
    public var width: Double?
    // transform family
    public var offset: [Double]?
    public var rotateDegrees: [Double]?
    public var scale: [Double]?
    /// "selectionCentroid" (default) | "origin" | [x, y, z]
    public var pivot: RecipePivot?
    // merge
    public var threshold: Double?
    public var targetVertex: Int?
    // material / subset tagging
    public var material: String?
    public var subset: String?

    public init(op: String, select: RecipeSelector? = nil, distance: Double? = nil,
                direction: [Double]? = nil, fraction: Double? = nil,
                width: Double? = nil, offset: [Double]? = nil,
                rotateDegrees: [Double]? = nil, scale: [Double]? = nil,
                pivot: RecipePivot? = nil, threshold: Double? = nil,
                targetVertex: Int? = nil, material: String? = nil,
                subset: String? = nil) {
        self.op = op
        self.select = select
        self.distance = distance
        self.direction = direction
        self.fraction = fraction
        self.width = width
        self.offset = offset
        self.rotateDegrees = rotateDegrees
        self.scale = scale
        self.pivot = pivot
        self.threshold = threshold
        self.targetVertex = targetVertex
        self.material = material
        self.subset = subset
    }
}

/// Pivot: a keyword string or an [x, y, z] point.
public enum RecipePivot: Codable, Equatable, Sendable {
    case keyword(String)
    case point([Double])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .keyword(s); return }
        self = .point(try container.decode([Double].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .keyword(let s): try container.encode(s)
        case .point(let p): try container.encode(p)
        }
    }
}

/// Component selector. Provide exactly one selection source; `within` may
/// additionally filter any face source. Sources:
/// - `all`: every face
/// - `faces` / `vertices`: explicit export-order indices
/// - `edges`: explicit [a, b] vertex-index pairs
/// - `facing` (+ optional `minDot`, default 0.9): faces whose unit normal
///   dot the given unit direction ≥ minDot
/// - `within`: axis-aligned box {min, max} over face centroids (alone or as a
///   filter on `all` / `facing`)
/// - `boundary`: all boundary edges (for fillHole / bevel on open meshes)
/// - `last`: the previous step's result selection
public struct RecipeSelector: Codable, Equatable, Sendable {
    public var all: Bool?
    public var faces: [Int]?
    public var vertices: [Int]?
    public var edges: [[Int]]?
    public var facing: [Double]?
    public var minDot: Double?
    public var within: RecipeBounds?
    public var boundary: Bool?
    public var last: Bool?

    public init(all: Bool? = nil, faces: [Int]? = nil, vertices: [Int]? = nil,
                edges: [[Int]]? = nil, facing: [Double]? = nil,
                minDot: Double? = nil, within: RecipeBounds? = nil,
                boundary: Bool? = nil, last: Bool? = nil) {
        self.all = all
        self.faces = faces
        self.vertices = vertices
        self.edges = edges
        self.facing = facing
        self.minDot = minDot
        self.within = within
        self.boundary = boundary
        self.last = last
    }
}

public struct RecipeBounds: Codable, Equatable, Sendable {
    public var min: [Double]
    public var max: [Double]

    public init(min: [Double], max: [Double]) {
        self.min = min
        self.max = max
    }
}
