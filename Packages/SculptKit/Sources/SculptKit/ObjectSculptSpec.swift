import Foundation
import MeshKit

/// The kind of geometry a component node realizes. Mirrors img2threejs's
/// "primitives + procedural, no mesh downloads" default: a node is either a
/// pure container (`group`), a parametric primitive, or a reference to a
/// built-in `ShapeLibrary` prefab (validated against `MeshKit.ShapeLibrary`).
public enum ShapeKind: Codable, Sendable, Equatable {
    case group
    case primitive(Primitive)
    case library(entryID: String)

    /// The five parametric primitives the MCP `create_mesh` tool can author.
    public enum Primitive: String, Codable, Sendable, CaseIterable {
        case plane, box, cylinder, cone, sphere
    }

    /// True when this kind authors geometry (everything but `group`).
    public var authorsGeometry: Bool {
        if case .group = self { return false }
        return true
    }
}

/// A physically-based material in the spec, kept channel-independent
/// (albedo/roughness/metallic/emissive) like img2threejs's material system.
public struct MaterialSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Linear RGB in 0...1.
    public var baseColor: [Double]
    public var roughness: Double
    public var metallic: Double
    /// Optional emissive RGB in 0...1.
    public var emissive: [Double]?

    public init(id: String, baseColor: [Double], roughness: Double = 0.5,
                metallic: Double = 0, emissive: [Double]? = nil) {
        self.id = id
        self.baseColor = baseColor
        self.roughness = roughness
        self.metallic = metallic
        self.emissive = emissive
    }
}

/// A named attachment point (for rigging / props), authored in the interaction
/// pass. Position is local to the component root.
public struct Socket: Codable, Sendable, Equatable {
    public var name: String
    public var translation: [Double]

    public init(name: String, translation: [Double]) {
        self.name = name
        self.translation = translation
    }
}

/// A linear repetition system (bolts around a rim, slats on a bench…). The
/// structural pass expands `count` copies, each offset by `step`.
public struct RepetitionSystem: Codable, Sendable, Equatable {
    public var name: String
    public var count: Int
    public var step: [Double]

    public init(name: String, count: Int, step: [Double]) {
        self.name = name
        self.count = count
        self.step = step
    }
}

/// One node in the component tree: its shape, local transform, bound material,
/// optional repetition, and children.
public struct ComponentNode: Codable, Sendable, Equatable, Identifiable {
    /// USD-identifier-safe name, unique among its siblings; also the node id.
    public var id: String { name }
    public var name: String
    public var shape: ShapeKind
    public var translation: [Double]
    public var rotationEulerDegrees: [Double]
    public var scale: [Double]
    /// Parametric dimensions for primitive shapes.
    public var width: Double
    public var height: Double
    public var depth: Double
    public var radius: Double
    public var segments: Int
    public var materialID: String?
    public var repetition: RepetitionSystem?
    public var children: [ComponentNode]

    public init(
        name: String, shape: ShapeKind,
        translation: [Double] = [0, 0, 0],
        rotationEulerDegrees: [Double] = [0, 0, 0],
        scale: [Double] = [1, 1, 1],
        width: Double = 1, height: Double = 1, depth: Double = 1,
        radius: Double = 0.5, segments: Int = 16,
        materialID: String? = nil,
        repetition: RepetitionSystem? = nil,
        children: [ComponentNode] = []
    ) {
        self.name = name
        self.shape = shape
        self.translation = translation
        self.rotationEulerDegrees = rotationEulerDegrees
        self.scale = scale
        self.width = width
        self.height = height
        self.depth = depth
        self.radius = radius
        self.segments = segments
        self.materialID = materialID
        self.repetition = repetition
        self.children = children
    }

    /// This node plus all descendants, in depth-first order.
    public var flattened: [ComponentNode] {
        [self] + children.flatMap(\.flattened)
    }
}

/// The complete, validated specification of an object to be sculpted — the
/// USD-native analog of img2threejs's `ObjectSculptSpec`: a component tree,
/// materials, sockets, a detail inventory, and the per-pass review history.
public struct ObjectSculptSpec: Codable, Sendable, Equatable {
    public var name: String
    public var objectClass: ObjectClass
    public var root: ComponentNode
    public var materials: [MaterialSpec]
    public var sockets: [Socket]
    public var detailInventory: DetailInventory
    public var reviewHistory: [PassReview]

    public init(
        name: String, objectClass: ObjectClass, root: ComponentNode,
        materials: [MaterialSpec] = [], sockets: [Socket] = [],
        detailInventory: DetailInventory = DetailInventory(),
        reviewHistory: [PassReview] = []
    ) {
        self.name = name
        self.objectClass = objectClass
        self.root = root
        self.materials = materials
        self.sockets = sockets
        self.detailInventory = detailInventory
        self.reviewHistory = reviewHistory
    }

    /// Every node in the tree, depth-first.
    public var allNodes: [ComponentNode] { root.flattened }

    /// Total component count (nodes in the tree).
    public var componentCount: Int { allNodes.count }

    /// Declared material ids.
    public var materialIDs: Set<String> { Set(materials.map(\.id)) }

    /// Leaf nodes that author geometry (used for material-coverage checks).
    public var geometryLeaves: [ComponentNode] {
        allNodes.filter { $0.children.isEmpty && $0.shape.authorsGeometry }
    }

    /// Round-trip encode/decode helpers (spec is persisted as JSON between
    /// tool calls, mirroring img2threejs's on-disk spec).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> ObjectSculptSpec {
        try JSONDecoder().decode(ObjectSculptSpec.self, from: data)
    }
}
