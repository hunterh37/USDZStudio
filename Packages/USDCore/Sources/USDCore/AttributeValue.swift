/// A typed USD attribute value as surfaced by the bridge snapshot.
///
/// This is intentionally a *closed, RealityKit-relevant* subset (see PRD §4.2):
/// exotic value types arriving from other tools are preserved as
/// `.unsupported(typeName:)` so no data is silently destroyed.
public enum AttributeValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case token(String)
    /// An asset path, e.g. a texture file reference.
    case asset(String)
    /// A fixed-arity numeric vector (2, 3, or 4 components) or quaternion.
    case vector([Double])
    /// A 4×4 matrix in row-major order (16 elements).
    case matrix4([Double])
    case intArray([Int])
    case doubleArray([Double])
    case stringArray([String])
    /// A value whose USD type the editor does not model; preserved by name.
    case unsupported(typeName: String)

    /// A short human-readable type label for inspector display.
    public var typeLabel: String {
        switch self {
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .token: return "token"
        case .asset: return "asset"
        case .vector(let v): return "double\(v.count)"
        case .matrix4: return "matrix4d"
        case .intArray: return "int[]"
        case .doubleArray: return "double[]"
        case .stringArray: return "string[]"
        case .unsupported(let typeName): return typeName
        }
    }

    /// `true` when the editor can round-trip and author this value type
    /// (everything except `.unsupported`).
    public var isEditable: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

/// A named attribute on a prim.
public struct Attribute: Hashable, Sendable {
    public var name: String
    public var value: AttributeValue

    public init(name: String, value: AttributeValue) {
        self.name = name
        self.value = value
    }
}
