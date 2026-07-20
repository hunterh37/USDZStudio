import Foundation

/// Top-level grouping in the built-in content library. The primitives group is
/// the parametric stock; the prefabs group is the growing catalog of low-poly
/// real-world objects.
public enum LibraryGroup: String, CaseIterable, Sendable, Codable {
    case primitives
    case prefabs

    /// Human-facing section title.
    public var title: String {
        switch self {
        case .primitives: return "Primitive Shapes"
        case .prefabs: return "Low-Poly Objects"
        }
    }
}

/// A single insertable item in the library. `build` generates a fresh mesh on
/// demand — entries are cheap descriptors, geometry is only realized when the
/// user inserts one.
public struct ShapeEntry: Identifiable, Sendable {
    /// Stable identifier, unique across the whole library (used for selection
    /// and as the seed for the inserted prim's name).
    public let id: String
    /// Display name, e.g. "Pine Tree".
    public let name: String
    public let group: LibraryGroup
    /// Sub-section within the group, e.g. "Basic", "Nature", "Furniture".
    public let category: String
    /// SF Symbol name for the list row.
    public let systemImage: String
    /// Generates the mesh for this entry.
    public let build: @Sendable () throws -> HalfEdgeMesh

    public init(id: String, name: String, group: LibraryGroup, category: String,
                systemImage: String,
                build: @escaping @Sendable () throws -> HalfEdgeMesh) {
        self.id = id
        self.name = name
        self.group = group
        self.category = category
        self.systemImage = systemImage
        self.build = build
    }
}

/// The registry of built-in library content: parametric primitives plus
/// procedural low-poly prefabs, organized group → category → entry. This is
/// the shape/prefab analog of `ScriptLibrary`, and the single source of truth
/// the EditorUI library panel renders.
public enum ShapeLibrary {

    /// Every entry, in display order.
    public static let all: [ShapeEntry] = primitives + prefabs

    /// Entries in a group, in display order.
    public static func entries(in group: LibraryGroup) -> [ShapeEntry] {
        all.filter { $0.group == group }
    }

    /// Ordered, de-duplicated category names within a group (display order
    /// follows first appearance in `all`).
    public static func categories(in group: LibraryGroup) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries(in: group) where seen.insert(entry.category).inserted {
            ordered.append(entry.category)
        }
        return ordered
    }

    /// Entries within a specific group + category, in display order.
    public static func entries(in group: LibraryGroup, category: String) -> [ShapeEntry] {
        entries(in: group).filter { $0.category == category }
    }

    /// Looks up an entry by its stable id.
    public static func entry(id: String) -> ShapeEntry? {
        all.first { $0.id == id }
    }

    // MARK: - Primitive shapes

    private static let primitives: [ShapeEntry] = [
        ShapeEntry(id: "prim.plane", name: "Plane", group: .primitives,
                   category: "Basic", systemImage: "square") {
            try Primitives.plane()
        },
        ShapeEntry(id: "prim.cube", name: "Cube", group: .primitives,
                   category: "Basic", systemImage: "cube") {
            try Primitives.box()
        },
        ShapeEntry(id: "prim.sphere", name: "Sphere", group: .primitives,
                   category: "Basic", systemImage: "circle") {
            try Primitives.uvSphere(rings: 8, segments: 12)
        },
        ShapeEntry(id: "prim.cylinder", name: "Cylinder", group: .primitives,
                   category: "Basic", systemImage: "cylinder") {
            try Primitives.cylinder(radialSegments: 16)
        },
        ShapeEntry(id: "prim.cone", name: "Cone", group: .primitives,
                   category: "Basic", systemImage: "cone") {
            try Primitives.cone(radialSegments: 16)
        },
        ShapeEntry(id: "prim.pyramid", name: "Pyramid", group: .primitives,
                   category: "Basic", systemImage: "triangle") {
            try Primitives.cone(radius: 0.7, height: 1, radialSegments: 4)
        },
    ]

    // MARK: - Low-poly prefabs

    private static let prefabs: [ShapeEntry] = [
        // Nature
        ShapeEntry(id: "prefab.tree", name: "Tree", group: .prefabs,
                   category: "Nature", systemImage: "tree", build: Prefabs.tree),
        ShapeEntry(id: "prefab.pineTree", name: "Pine Tree", group: .prefabs,
                   category: "Nature", systemImage: "tree.fill", build: Prefabs.pineTree),
        ShapeEntry(id: "prefab.bush", name: "Bush", group: .prefabs,
                   category: "Nature", systemImage: "leaf", build: Prefabs.bush),
        ShapeEntry(id: "prefab.rock", name: "Rock", group: .prefabs,
                   category: "Nature", systemImage: "mountain.2", build: Prefabs.rock),
        ShapeEntry(id: "prefab.mushroom", name: "Mushroom", group: .prefabs,
                   category: "Nature", systemImage: "leaf.circle", build: Prefabs.mushroom),
        // Furniture
        ShapeEntry(id: "prefab.table", name: "Table", group: .prefabs,
                   category: "Furniture", systemImage: "table.furniture", build: Prefabs.table),
        ShapeEntry(id: "prefab.chair", name: "Chair", group: .prefabs,
                   category: "Furniture", systemImage: "chair", build: Prefabs.chair),
        ShapeEntry(id: "prefab.bench", name: "Bench", group: .prefabs,
                   category: "Furniture", systemImage: "chair.lounge", build: Prefabs.bench),
        // Structures
        ShapeEntry(id: "prefab.house", name: "House", group: .prefabs,
                   category: "Structures", systemImage: "house", build: Prefabs.house),
        ShapeEntry(id: "prefab.watchtower", name: "Watchtower", group: .prefabs,
                   category: "Structures", systemImage: "building.columns", build: Prefabs.watchtower),
        // Props
        ShapeEntry(id: "prefab.barrel", name: "Barrel", group: .prefabs,
                   category: "Props", systemImage: "cylinder.split.1x2", build: Prefabs.barrel),
        ShapeEntry(id: "prefab.crate", name: "Crate", group: .prefabs,
                   category: "Props", systemImage: "shippingbox", build: Prefabs.crate),
        ShapeEntry(id: "prefab.streetLamp", name: "Street Lamp", group: .prefabs,
                   category: "Props", systemImage: "lightbulb", build: Prefabs.streetLamp),
    ]
}
