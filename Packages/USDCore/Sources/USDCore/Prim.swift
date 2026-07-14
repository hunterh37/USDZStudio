/// Prim visibility per `UsdGeomImageable.visibility` semantics that matter to
/// RealityKit output (PRD §5.3: Hide vs. Deactivate).
public enum Visibility: String, Hashable, Sendable, Codable {
    /// Visible unless an ancestor is invisible.
    case inherited
    /// Hidden, but ships in the exported file and can be re-shown at runtime.
    case invisible
}

/// A variant set on a prim, e.g. `color = {red, blue, green}`.
public struct VariantSet: Hashable, Sendable {
    public var name: String
    public var variants: [String]
    public var selection: String?

    public init(name: String, variants: [String], selection: String? = nil) {
        self.name = name
        self.variants = variants
        self.selection = selection
    }

    /// `true` when `selection` names one of `variants` (or is `nil`).
    public var hasValidSelection: Bool {
        guard let selection else { return true }
        return variants.contains(selection)
    }
}

/// An immutable snapshot of a prim and its subtree.
///
/// The stage (via USDBridge) is the source of truth; `Prim` values are the
/// derived, observable projection consumed by the outliner, inspector, and
/// viewport (see `specs/architecture.md` — Core Data Flow).
public struct Prim: Hashable, Sendable {
    public var path: PrimPath
    /// The USD type name, e.g. `Xform`, `Mesh`, `Material`. Empty for typeless prims.
    public var typeName: String
    /// Deactivated prims are excluded from the composed stage (PRD "Deactivate/Remove").
    public var isActive: Bool
    public var visibility: Visibility
    public var attributes: [Attribute]
    public var metadata: [String: String]
    public var variantSets: [VariantSet]
    public var children: [Prim]

    public init(
        path: PrimPath,
        typeName: String = "",
        isActive: Bool = true,
        visibility: Visibility = .inherited,
        attributes: [Attribute] = [],
        metadata: [String: String] = [:],
        variantSets: [VariantSet] = [],
        children: [Prim] = []
    ) {
        self.path = path
        self.typeName = typeName
        self.isActive = isActive
        self.visibility = visibility
        self.attributes = attributes
        self.metadata = metadata
        self.variantSets = variantSets
        self.children = children
    }

    /// The prim's name — the last component of its path.
    public var name: String { path.name }

    /// First attribute with the given name, if any.
    public func attribute(named name: String) -> Attribute? {
        attributes.first { $0.name == name }
    }

    /// Depth-first traversal of this prim and all descendants.
    public func flattened() -> [Prim] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// Finds a descendant (or self) by absolute path.
    public func prim(at target: PrimPath) -> Prim? {
        if target == path { return self }
        guard path.isAncestor(of: target) else { return nil }
        for child in children {
            if let found = child.prim(at: target) { return found }
        }
        return nil
    }
}
