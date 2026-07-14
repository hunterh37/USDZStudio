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
    /// A `token[]` array (distinct from `string[]`); used by UsdSkel `joints`.
    case tokenArray([String])
    /// A `float3[]` array, flattened (length a multiple of 3). Used by UsdSkel
    /// skeletal translation/scale samples.
    case float3Array([Double])
    /// A `quatf[]` array, flattened as (w, x, y, z) per element (length a
    /// multiple of 4). Used by UsdSkel rotation samples.
    case quatfArray([Double])
    /// A `matrix4d[]` array, flattened row-major (length a multiple of 16).
    /// Used by UsdSkel bind/rest transforms.
    case matrix4dArray([Double])
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
        case .tokenArray: return "token[]"
        case .float3Array: return "float3[]"
        case .quatfArray: return "quatf[]"
        case .matrix4dArray: return "matrix4d[]"
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

/// One keyframe of a time-sampled attribute: a time code and the value at it.
public struct TimeSample: Hashable, Sendable {
    public var time: Double
    public var value: AttributeValue

    public init(time: Double, value: AttributeValue) {
        self.time = time
        self.value = value
    }
}

/// A named attribute on a prim.
///
/// An attribute is either static (`timeSamples == nil`, using `value`) or
/// animated (`timeSamples` non-empty; `value` still carries the fallback and,
/// crucially, the declared type). `isUniform` and `metadata` model the USD
/// attribute qualifiers UsdSkel relies on (`uniform`, `elementSize`,
/// `interpolation`).
public struct Attribute: Hashable, Sendable {
    public var name: String
    public var value: AttributeValue
    public var isUniform: Bool
    /// Attribute metadata authored inside the trailing `( … )`, e.g.
    /// `elementSize` and `interpolation`. Emitted in sorted-key order.
    public var metadata: [String: String]
    /// Time samples, sorted by time when authored; `nil` for static attributes.
    public var timeSamples: [TimeSample]?

    public init(
        name: String,
        value: AttributeValue,
        isUniform: Bool = false,
        metadata: [String: String] = [:],
        timeSamples: [TimeSample]? = nil
    ) {
        self.name = name
        self.value = value
        self.isUniform = isUniform
        self.metadata = metadata
        self.timeSamples = timeSamples
    }

    /// `true` when the attribute carries time samples.
    public var isAnimated: Bool { timeSamples?.isEmpty == false }
}

/// A USD relationship: a named, typed pointer from one prim to others
/// (e.g. `skel:skeleton`, `skel:animationSource`, `material:binding`).
public struct Relationship: Hashable, Sendable {
    public var name: String
    public var targets: [PrimPath]
    public var isUniform: Bool

    public init(name: String, targets: [PrimPath], isUniform: Bool = false) {
        self.name = name
        self.targets = targets
        self.isUniform = isUniform
    }
}
