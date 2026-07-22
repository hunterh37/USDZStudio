import Foundation
import MeshKit
import MechanismKit

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

    // MARK: - Codable

    /// Friendly, guessable wire form (issue #112). Instead of Swift's default
    /// enum-with-associated-value coding — which leaks the `_0` synthesized key
    /// (`{"primitive":{"_0":"box"}}`) that is impossible to author blind — a
    /// `ShapeKind` encodes as a tagged object:
    ///   • group     → `{"kind":"group"}`
    ///   • primitive → `{"kind":"primitive","primitive":"box"}`
    ///   • library   → `{"kind":"library","entryID":"…"}`
    /// Decoding accepts that form AND the legacy `_0`/associated-value form, so
    /// specs persisted before this change still load.
    private enum CodingKeys: String, CodingKey {
        case kind, primitive, entryID
        // Legacy associated-value keys (default synthesized coding).
        case group, library
    }

    private enum Tag: String, Codable { case group, primitive, library }

    private enum LegacyPrimitiveKeys: String, CodingKey { case _0 }
    private enum LegacyLibraryKeys: String, CodingKey { case entryID }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group:
            try c.encode(Tag.group, forKey: .kind)
        case .primitive(let primitive):
            try c.encode(Tag.primitive, forKey: .kind)
            try c.encode(primitive, forKey: .primitive)
        case .library(let entryID):
            try c.encode(Tag.library, forKey: .kind)
            try c.encode(entryID, forKey: .entryID)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Preferred friendly form: a `kind` discriminator.
        if let tag = try c.decodeIfPresent(Tag.self, forKey: .kind) {
            switch tag {
            case .group:
                self = .group
            case .primitive:
                self = .primitive(try c.decode(Primitive.self, forKey: .primitive))
            case .library:
                self = .library(entryID: try c.decode(String.self, forKey: .entryID))
            }
            return
        }
        // Legacy fallback: Swift's default associated-value coding.
        if c.contains(.group) {
            self = .group
        } else if let nested = try? c.nestedContainer(keyedBy: LegacyPrimitiveKeys.self, forKey: .primitive) {
            self = .primitive(try nested.decode(Primitive.self, forKey: ._0))
        } else if let nested = try? c.nestedContainer(keyedBy: LegacyLibraryKeys.self, forKey: .library) {
            self = .library(entryID: try nested.decode(String.self, forKey: .entryID))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ShapeKind: expected a \"kind\" of group/primitive/library"))
        }
    }
}

/// A physically-based material in the spec, kept channel-independent
/// (albedo/roughness/metallic/emissive) like img2threejs's material system.
///
/// Beyond the flat scalar/colour channels it can carry optional **texture
/// maps** (asset path strings) so the material pass authors real image
/// channels — albedo, normal, roughness, and emissive — not just a solid
/// colour. `normalScale` tunes the strength of the normal map. Every map field
/// is optional and decode-defaulted so specs authored before texture support
/// still load unchanged.
public struct MaterialSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Linear RGB in 0...1.
    public var baseColor: [Double]
    public var roughness: Double
    public var metallic: Double
    /// Optional emissive RGB in 0...1.
    public var emissive: [Double]?
    /// Optional albedo/base-colour texture asset path.
    public var albedoMap: String?
    /// Optional tangent-space normal-map asset path.
    public var normalMap: String?
    /// Optional roughness texture asset path.
    public var roughnessMap: String?
    /// Optional emissive texture asset path.
    public var emissiveMap: String?
    /// Strength applied to the normal map (>= 0; 1 = full strength).
    public var normalScale: Double?

    public init(id: String, baseColor: [Double], roughness: Double = 0.5,
                metallic: Double = 0, emissive: [Double]? = nil,
                albedoMap: String? = nil, normalMap: String? = nil,
                roughnessMap: String? = nil, emissiveMap: String? = nil,
                normalScale: Double? = nil) {
        self.id = id
        self.baseColor = baseColor
        self.roughness = roughness
        self.metallic = metallic
        self.emissive = emissive
        self.albedoMap = albedoMap
        self.normalMap = normalMap
        self.roughnessMap = roughnessMap
        self.emissiveMap = emissiveMap
        self.normalScale = normalScale
    }

    // Custom decoding so specs authored before texture channels existed still
    // decode (every map field and normalScale decode-default to nil).
    private enum CodingKeys: String, CodingKey {
        case id, baseColor, roughness, metallic, emissive
        case albedoMap, normalMap, roughnessMap, emissiveMap, normalScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        baseColor = try c.decode([Double].self, forKey: .baseColor)
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 0.5
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic) ?? 0
        emissive = try c.decodeIfPresent([Double].self, forKey: .emissive)
        albedoMap = try c.decodeIfPresent(String.self, forKey: .albedoMap)
        normalMap = try c.decodeIfPresent(String.self, forKey: .normalMap)
        roughnessMap = try c.decodeIfPresent(String.self, forKey: .roughnessMap)
        emissiveMap = try c.decodeIfPresent(String.self, forKey: .emissiveMap)
        normalScale = try c.decodeIfPresent(Double.self, forKey: .normalScale)
    }

    /// True when the material carries at least one texture map.
    public var hasTextures: Bool {
        albedoMap != nil || normalMap != nil || roughnessMap != nil || emissiveMap != nil
    }
}

/// A camera pose for a projected-texture bake: eye position, the point it looks
/// at, and its up vector. Pure data — SculptKit never renders it.
public struct CameraPose: Codable, Sendable, Equatable {
    public var position: [Double]
    public var target: [Double]
    public var up: [Double]

    public init(position: [Double], target: [Double], up: [Double] = [0, 1, 0]) {
        self.position = position
        self.target = target
        self.up = up
    }
}

/// A projected-texture / de-light descriptor for the surface pass — the
/// USD-native analog of img2threejs's `bake_projected_texture` +
/// `delight_albedo`. It describes *how* a reference image is projected onto a
/// component's UV set (and whether to de-light the resulting albedo); the
/// executor realizes it, keeping SculptKit free of any image processing.
public struct SurfaceProjection: Codable, Sendable, Equatable {
    /// Component node the projection targets.
    public var targetComponent: String
    /// Camera the reference is projected from.
    public var camera: CameraPose
    /// Destination UV set (e.g. "st").
    public var uvSet: String
    /// Whether to remove baked lighting from the projected albedo.
    public var delight: Bool

    public init(targetComponent: String, camera: CameraPose,
                uvSet: String = "st", delight: Bool = true) {
        self.targetComponent = targetComponent
        self.camera = camera
        self.uvSet = uvSet
        self.delight = delight
    }

    /// Deterministic JSON (sorted keys) for authoring onto the stage.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// A proportion-lock landmark for character specs: a named anchor bound to a
/// component at a normalized position (e.g. head-top, hip, foot). Character
/// specs must declare landmarks so proportions stay deterministic across
/// rebuilds. Pure data.
public struct Landmark: Codable, Sendable, Equatable {
    public var name: String
    /// Component node this landmark anchors to.
    public var component: String
    /// Anchor position (local to the component root).
    public var position: [Double]

    public init(name: String, component: String, position: [Double]) {
        self.name = name
        self.component = component
        self.position = position
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

/// How a repetition system lays out its copies.
public enum RepetitionKind: String, Codable, Sendable, Equatable {
    /// Copies offset by `step * i` (slats on a bench).
    case linear
    /// Copies revolved around `axis` through the base, evenly over 360°
    /// (bolts around a rim). `step` is the radial offset applied before the
    /// rotation, so the first copy sits `step` away from the pivot.
    case radial
    /// Copies laid out on a `gridCounts` = [nx, ny, nz] lattice, spaced by
    /// `step` on each axis (rivets on a panel).
    case grid
}

/// A repetition system (bolts around a rim, slats on a bench, rivets on a
/// panel…). The structural pass expands the copies according to `kind`.
public struct RepetitionSystem: Codable, Sendable, Equatable {
    public var name: String
    public var kind: RepetitionKind
    public var count: Int
    public var step: [Double]
    /// Rotation axis for `.radial` (defaults to +Y when nil).
    public var axis: [Double]?
    /// Per-axis counts [nx, ny, nz] for `.grid` (defaults derived from `count`).
    public var gridCounts: [Int]?

    public init(name: String, kind: RepetitionKind = .linear, count: Int, step: [Double],
                axis: [Double]? = nil, gridCounts: [Int]? = nil) {
        self.name = name
        self.kind = kind
        self.count = count
        self.step = step
        self.axis = axis
        self.gridCounts = gridCounts
    }

    // Custom decoding so specs authored before `kind`/`axis`/`gridCounts`
    // existed still decode (kind defaults to `.linear`).
    private enum CodingKeys: String, CodingKey { case name, kind, count, step, axis, gridCounts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(RepetitionKind.self, forKey: .kind) ?? .linear
        count = try c.decode(Int.self, forKey: .count)
        step = try c.decode([Double].self, forKey: .step)
        axis = try c.decodeIfPresent([Double].self, forKey: .axis)
        gridCounts = try c.decodeIfPresent([Int].self, forKey: .gridCounts)
    }
}

/// A runtime collision volume wrapping a component (part of the "action-ready"
/// runtime layer img2threejs exposes via `sculptRuntime`).
public struct Collider: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case box, sphere, capsule, convexHull
    }
    public var name: String
    public var kind: Kind
    /// Name of the component node this collider wraps.
    public var component: String
    public var center: [Double]
    public var size: [Double]

    public init(name: String, kind: Kind, component: String,
                center: [Double] = [0, 0, 0], size: [Double] = [1, 1, 1]) {
        self.name = name
        self.kind = kind
        self.component = component
        self.center = center
        self.size = size
    }
}

/// A named group of components that break away together at runtime.
public struct DestructionGroup: Codable, Sendable, Equatable {
    public var name: String
    /// Component node names that belong to this group.
    public var members: [String]

    public init(name: String, members: [String]) {
        self.name = name
        self.members = members
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
    /// How this node joins its parent (img2threejs's "declare a join method").
    /// Decode-defaults to nil; the attachment gate treats nil as unspecified.
    public var attachment: AttachmentKind?
    /// Real geometry-refinement ops the `formRefinement` pass applies to this
    /// node's authored mesh (executed via MeshKit). Decode-defaults to `[]`.
    public var refinements: [MeshRefinement]
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
        attachment: AttachmentKind? = nil,
        refinements: [MeshRefinement] = [],
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
        self.attachment = attachment
        self.refinements = refinements
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case name, shape, translation, rotationEulerDegrees, scale
        case width, height, depth, radius, segments
        case materialID, repetition, attachment, refinements, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        shape = try c.decode(ShapeKind.self, forKey: .shape)
        translation = try c.decodeIfPresent([Double].self, forKey: .translation) ?? [0, 0, 0]
        rotationEulerDegrees = try c.decodeIfPresent([Double].self, forKey: .rotationEulerDegrees) ?? [0, 0, 0]
        scale = try c.decodeIfPresent([Double].self, forKey: .scale) ?? [1, 1, 1]
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 1
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.5
        segments = try c.decodeIfPresent(Int.self, forKey: .segments) ?? 16
        materialID = try c.decodeIfPresent(String.self, forKey: .materialID)
        repetition = try c.decodeIfPresent(RepetitionSystem.self, forKey: .repetition)
        attachment = try c.decodeIfPresent(AttachmentKind.self, forKey: .attachment)
        refinements = try c.decodeIfPresent([MeshRefinement].self, forKey: .refinements) ?? []
        children = try c.decodeIfPresent([ComponentNode].self, forKey: .children) ?? []
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
    /// Rigid articulations — hinges/sliders that make a component open, close,
    /// or swing (a lid, door, cap, drawer). Authored in the interaction pass;
    /// each `target` must name a component. See `specs/articulation-mechanisms.md`.
    public var joints: [Joint]
    /// Runtime collision volumes (authored in the interaction pass).
    public var colliders: [Collider]
    /// Runtime destruction groups (authored in the interaction pass).
    public var destructionGroups: [DestructionGroup]
    /// Optional projected-texture / de-light descriptor realized in the surface pass.
    public var surfaceProjection: SurfaceProjection?
    /// Proportion-lock landmarks (required for `.character` specs).
    public var landmarks: [Landmark]
    /// Real lights authored by the lighting pass (`UsdLux`).
    public var lights: [LightSpec]
    /// Level-of-detail tiers authored by the optimization pass.
    public var lodTiers: [LODTier]
    /// Real vertex-welding decimation applied to every geometry leaf by the
    /// optimization pass. Decode-defaults to nil (LOD-manifest-only behaviour).
    public var optimization: OptimizationSpec?
    public var detailInventory: DetailInventory
    public var reviewHistory: [PassReview]

    public init(
        name: String, objectClass: ObjectClass, root: ComponentNode,
        materials: [MaterialSpec] = [], sockets: [Socket] = [],
        joints: [Joint] = [],
        colliders: [Collider] = [], destructionGroups: [DestructionGroup] = [],
        surfaceProjection: SurfaceProjection? = nil, landmarks: [Landmark] = [],
        lights: [LightSpec] = [], lodTiers: [LODTier] = [],
        optimization: OptimizationSpec? = nil,
        detailInventory: DetailInventory = DetailInventory(),
        reviewHistory: [PassReview] = []
    ) {
        self.name = name
        self.objectClass = objectClass
        self.root = root
        self.materials = materials
        self.sockets = sockets
        self.joints = joints
        self.colliders = colliders
        self.destructionGroups = destructionGroups
        self.surfaceProjection = surfaceProjection
        self.landmarks = landmarks
        self.lights = lights
        self.lodTiers = lodTiers
        self.optimization = optimization
        self.detailInventory = detailInventory
        self.reviewHistory = reviewHistory
    }

    // Custom decoding so specs authored before the runtime/surface/character
    // layers still decode.
    private enum CodingKeys: String, CodingKey {
        case name, objectClass, root, materials, sockets, joints
        case colliders, destructionGroups, surfaceProjection, landmarks
        case lights, lodTiers, optimization, detailInventory, reviewHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        objectClass = try c.decode(ObjectClass.self, forKey: .objectClass)
        root = try c.decode(ComponentNode.self, forKey: .root)
        materials = try c.decodeIfPresent([MaterialSpec].self, forKey: .materials) ?? []
        sockets = try c.decodeIfPresent([Socket].self, forKey: .sockets) ?? []
        joints = try c.decodeIfPresent([Joint].self, forKey: .joints) ?? []
        colliders = try c.decodeIfPresent([Collider].self, forKey: .colliders) ?? []
        destructionGroups = try c.decodeIfPresent([DestructionGroup].self, forKey: .destructionGroups) ?? []
        surfaceProjection = try c.decodeIfPresent(SurfaceProjection.self, forKey: .surfaceProjection)
        landmarks = try c.decodeIfPresent([Landmark].self, forKey: .landmarks) ?? []
        lights = try c.decodeIfPresent([LightSpec].self, forKey: .lights) ?? []
        lodTiers = try c.decodeIfPresent([LODTier].self, forKey: .lodTiers) ?? []
        optimization = try c.decodeIfPresent(OptimizationSpec.self, forKey: .optimization)
        detailInventory = try c.decodeIfPresent(DetailInventory.self, forKey: .detailInventory) ?? DetailInventory()
        reviewHistory = try c.decodeIfPresent([PassReview].self, forKey: .reviewHistory) ?? []
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
