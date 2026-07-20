import Foundation

/// A minimal, dependency-free JSON value used for every MCP payload.
///
/// The MCP layer speaks JSON-RPC over stdio (docs/AGENT_MCP_PLAN.md §2); the
/// repo carries no external packages, so this enum is the whole JSON model:
/// Codable both ways, order-stable object encoding via sorted keys is left to
/// JSONSerialization, and ergonomic accessors for tool-parameter decoding.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            // coverage:disable — defensive: JSONDecoder input always matches one of the six JSON types above; kept so a future decoder change fails loudly.
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
            // coverage:enable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            // Emit integral numbers without a fraction so ids round-trip.
            if n.rounded() == n, abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Accessors

public extension JSONValue {
    var isNull: Bool { self == .null }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n else { return nil }
        return Int(n)
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> JSONValue {
        objectValue?[key] ?? .null
    }

    /// `[1, 2, 3]` → `[Double]`; `nil` when any element is non-numeric.
    var doubleArrayValue: [Double]? {
        guard let items = arrayValue else { return nil }
        var out: [Double] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let d = item.doubleValue else { return nil }
            out.append(d)
        }
        return out
    }

    var intArrayValue: [Int]? {
        guard let items = arrayValue else { return nil }
        var out: [Int] = []
        for item in items {
            guard let i = item.intValue else { return nil }
            out.append(i)
        }
        return out
    }

    var stringArrayValue: [String]? {
        guard let items = arrayValue else { return nil }
        var out: [String] = []
        for item in items {
            guard let s = item.stringValue else { return nil }
            out.append(s)
        }
        return out
    }
}

// MARK: - Serialization

public extension JSONValue {
    /// Decode from raw JSON bytes.
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encode to compact JSON bytes (stable across runs via sorted keys).
    func serialized() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding this enum cannot fail: every case maps to a JSON type.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var serializedString: String {
        String(decoding: serialized(), as: UTF8.self)
    }
}
