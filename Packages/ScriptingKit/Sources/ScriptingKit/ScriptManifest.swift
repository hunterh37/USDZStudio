import Foundation

/// The declarative header a bundled script exposes via its `MANIFEST` dict
/// (see `Resources/Python/scripts/_harness.py`). The Swift host learns a
/// script's identity, whether it mutates the stage, and its parameter schema
/// by asking the script to emit this as JSON (`--emit-manifest`) — so the
/// in-app runner never has to parse Python.
public struct ScriptManifest: Equatable, Sendable, Codable {

    public var name: String
    public var description: String
    /// Whether running the script changes the stage (drives whether we ask for
    /// an output file and offer a re-import, vs. a read-only report script).
    public var mutates: Bool
    public var arguments: [ScriptArgument]

    public init(name: String, description: String = "", mutates: Bool = false,
                arguments: [ScriptArgument] = []) {
        self.name = name
        self.description = description
        self.mutates = mutates
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, mutates
        case arguments = "args"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        mutates = try c.decodeIfPresent(Bool.self, forKey: .mutates) ?? false
        arguments = try c.decodeIfPresent([ScriptArgument].self, forKey: .arguments) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(mutates, forKey: .mutates)
        try c.encode(arguments, forKey: .arguments)
    }

    /// Decodes a manifest from the JSON a script prints for `--emit-manifest`.
    public static func decode(fromJSON data: Data) throws -> ScriptManifest {
        try JSONDecoder().decode(ScriptManifest.self, from: data)
    }

    public func argument(named name: String) -> ScriptArgument? {
        arguments.first { $0.name == name }
    }
}

/// One parameter a script accepts. Types mirror `_harness.py`'s `_types` plus
/// `bool` (which becomes a presence flag on the command line).
public struct ScriptArgument: Equatable, Sendable, Codable {

    public enum Kind: String, Sendable, Codable {
        case int, float, string = "str", bool

        public init(rawFromManifest raw: String) {
            self = Kind(rawValue: raw) ?? .string
        }
    }

    /// A default value carried through from the manifest, preserving its JSON
    /// type so the parameter sheet can seed fields correctly.
    public enum DefaultValue: Equatable, Sendable {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)

        /// Rendered for seeding a text field / toggle.
        public var displayString: String {
            switch self {
            case .int(let v): return String(v)
            case .double(let v): return String(v)
            case .string(let v): return v
            case .bool(let v): return v ? "true" : "false"
            }
        }

        public var boolValue: Bool {
            switch self {
            case .bool(let v): return v
            case .int(let v): return v != 0
            case .double(let v): return v != 0
            case .string(let v): return ScriptArgument.isTruthy(v)
            }
        }
    }

    public var name: String
    public var kind: Kind
    public var help: String
    /// `nil` when the manifest default is JSON `null` (no default supplied).
    public var defaultValue: DefaultValue?

    public init(name: String, kind: Kind, help: String = "",
                defaultValue: DefaultValue? = nil) {
        self.name = name
        self.kind = kind
        self.help = help
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, help
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = Kind(rawFromManifest: try c.decodeIfPresent(String.self, forKey: .type) ?? "str")
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""

        // The default arrives as an arbitrary JSON scalar (or null / absent).
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .defaultValue) {
            defaultValue = .bool(b)
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .defaultValue) {
            defaultValue = .int(i)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .defaultValue) {
            defaultValue = .double(d)
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .defaultValue) {
            defaultValue = .string(s)
        } else {
            defaultValue = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind.rawValue, forKey: .type)
        try c.encode(help, forKey: .help)
        switch defaultValue {
        case .int(let v): try c.encode(v, forKey: .defaultValue)
        case .double(let v): try c.encode(v, forKey: .defaultValue)
        case .string(let v): try c.encode(v, forKey: .defaultValue)
        case .bool(let v): try c.encode(v, forKey: .defaultValue)
        case nil: try c.encodeNil(forKey: .defaultValue)
        }
    }

    /// Command-line flag stem: `_harness.py` maps `snake_case` → `--snake-case`.
    public var flag: String {
        "--" + name.replacingOccurrences(of: "_", with: "-")
    }

    public static func isTruthy(_ raw: String) -> Bool {
        ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
