import Foundation

/// An absolute path to a prim on a USD stage, e.g. `/Car/Wheels/FrontLeft`.
///
/// `PrimPath` is a pure value type: it performs no I/O and never touches
/// Python, RealityKit, or SwiftUI (see `specs/architecture.md`).
public struct PrimPath: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {

    /// Path components from the root, e.g. `["Car", "Wheels", "FrontLeft"]`.
    public let components: [String]

    /// The absolute root path `/`.
    public static let root = PrimPath(validatedComponents: [])

    // MARK: Construction

    init(validatedComponents: [String]) {
        self.components = validatedComponents
    }

    /// Parses an absolute path string like `/Car/Wheels`. Returns `nil` when the
    /// string is not an absolute path composed of valid prim names.
    public init?(_ string: String) {
        guard string.hasPrefix("/") else { return nil }
        if string == "/" {
            self.components = []
            return
        }
        let parts = string.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(PrimPath.isValidName) else { return nil }
        self.components = parts
    }

    /// Builds a path from pre-split components, validating each name.
    public init?(components: [String]) {
        guard components.allSatisfy(PrimPath.isValidName) else { return nil }
        self.components = components
    }

    // MARK: Properties

    /// `true` for the stage root `/`.
    public var isRoot: Bool { components.isEmpty }

    /// The final path component, or `/` for the root path.
    public var name: String { components.last ?? "/" }

    /// Number of components below the root (root has depth 0).
    public var depth: Int { components.count }

    /// The parent path; the root's parent is the root itself.
    public var parent: PrimPath {
        isRoot ? self : PrimPath(validatedComponents: Array(components.dropLast()))
    }

    public var description: String {
        isRoot ? "/" : "/" + components.joined(separator: "/")
    }

    // MARK: Derivation

    /// Returns this path with `name` appended, or `nil` if `name` is invalid.
    public func appending(_ name: String) -> PrimPath? {
        guard PrimPath.isValidName(name) else { return nil }
        return PrimPath(validatedComponents: components + [name])
    }

    /// Strict ancestry: the root is an ancestor of everything but itself.
    public func isAncestor(of other: PrimPath) -> Bool {
        depth < other.depth && Array(other.components.prefix(depth)) == components
    }

    public func isDescendant(of other: PrimPath) -> Bool {
        other.isAncestor(of: self)
    }

    /// The deepest path that is an ancestor-or-self of both paths.
    public func commonAncestor(with other: PrimPath) -> PrimPath {
        var shared: [String] = []
        for (a, b) in zip(components, other.components) {
            guard a == b else { break }
            shared.append(a)
        }
        return PrimPath(validatedComponents: shared)
    }

    // MARK: Name validation & sanitization

    /// A valid prim name starts with a letter or `_`, followed by letters,
    /// digits, or `_` (the USD identifier rule).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    /// Rewrites an arbitrary string into a valid prim name: invalid characters
    /// become `_`, a leading digit gains a `_` prefix, empty input becomes `_`.
    /// Guaranteed to produce a name for which `isValidName` returns `true`.
    public static func sanitizedName(from raw: String) -> String {
        var scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        if scalars.isEmpty { scalars = ["_"] }
        var result = String(scalars)
        if let first = result.unicodeScalars.first,
           !CharacterSet.letters.contains(first), first != "_" {
            result = "_" + result
        }
        return result
    }

    // MARK: Comparable (lexicographic by component)

    public static func < (lhs: PrimPath, rhs: PrimPath) -> Bool {
        for (a, b) in zip(lhs.components, rhs.components) where a != b {
            return a < b
        }
        return lhs.depth < rhs.depth
    }

    // MARK: Codable (as the string form)

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let path = PrimPath(string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid prim path: \(string)"))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
