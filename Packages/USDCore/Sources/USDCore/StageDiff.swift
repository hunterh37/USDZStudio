import Foundation

/// A structural difference between two USD stage snapshots.
///
/// `StageDiff` answers the roadmap's "compare two files / before-after an edit
/// batch" question (ROADMAP §Continuous — *USD stage diff view*). It is a pure
/// value type computed from two `USDStageProtocol` values: it performs no I/O
/// and touches neither Python nor RealityKit, so it lives in `USDCore` and is
/// reusable by the CLI (`openusdz diff`), a future diff panel, and the agent
/// layer alike.
///
/// The comparison is deliberately *shallow-per-prim*: prims are matched by
/// absolute path across the whole (flattened) stage, so a moved or renamed prim
/// reads as one removal plus one addition rather than a mutation — the same way
/// `usddiff` reports namespace edits. Every scalar change is captured uniformly
/// as a `ValueChange` (`before`/`after`, `nil` meaning "absent"), which keeps
/// rendering and JSON trivial while preserving which field changed.
public struct StageDiff: Equatable, Sendable, Codable {

    /// One before→after change of a single field. A `nil` side means the field
    /// (or keyed entry) was absent on that side — an add (`before == nil`) or a
    /// removal (`after == nil`).
    public struct ValueChange: Equatable, Sendable, Codable {
        public var label: String
        public var before: String?
        public var after: String?

        public init(label: String, before: String?, after: String?) {
            self.label = label
            self.before = before
            self.after = after
        }
    }

    /// A prim identified for the added/removed lists: its path plus type, so the
    /// reader sees *what* appeared or vanished, not just where.
    public struct PrimRef: Equatable, Sendable, Codable {
        public var path: PrimPath
        public var typeName: String

        public init(path: PrimPath, typeName: String) {
            self.path = path
            self.typeName = typeName
        }
    }

    /// The field-level changes on a prim that exists in both stages.
    public struct PrimDiff: Equatable, Sendable, Codable {
        public var path: PrimPath
        public var changes: [ValueChange]

        public init(path: PrimPath, changes: [ValueChange]) {
            self.path = path
            self.changes = changes
        }
    }

    /// Root-layer metadata changes.
    public var metadata: [ValueChange]
    /// Prims present only in the *after* stage, sorted by path.
    public var addedPrims: [PrimRef]
    /// Prims present only in the *before* stage, sorted by path.
    public var removedPrims: [PrimRef]
    /// Prims present in both but with differing fields, sorted by path.
    public var changedPrims: [PrimDiff]

    public init(
        metadata: [ValueChange] = [],
        addedPrims: [PrimRef] = [],
        removedPrims: [PrimRef] = [],
        changedPrims: [PrimDiff] = []
    ) {
        self.metadata = metadata
        self.addedPrims = addedPrims
        self.removedPrims = removedPrims
        self.changedPrims = changedPrims
    }

    /// `true` when the two stages are structurally identical.
    public var isEmpty: Bool {
        metadata.isEmpty && addedPrims.isEmpty && removedPrims.isEmpty && changedPrims.isEmpty
    }

    // MARK: - Computation

    /// Computes the difference `before → after`.
    public static func between(
        _ before: some USDStageProtocol,
        _ after: some USDStageProtocol
    ) -> StageDiff {
        StageDiff(
            metadata: metadataChanges(before.metadata, after.metadata),
            addedPrims: [],
            removedPrims: [],
            changedPrims: []
        ).withPrimChanges(before: before.allPrims(), after: after.allPrims())
    }

    /// Fills in the prim add/remove/change lists from the two flattened prim
    /// lists. Split out from `between` only to keep each step readable.
    private func withPrimChanges(before: [Prim], after: [Prim]) -> StageDiff {
        let beforeByPath = Dictionary(before.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByPath = Dictionary(after.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        let beforePaths = Set(beforeByPath.keys)
        let afterPaths = Set(afterByPath.keys)

        var added: [PrimRef] = []
        var removed: [PrimRef] = []
        var changed: [PrimDiff] = []

        for path in afterPaths.subtracting(beforePaths).sorted() {
            if let prim = afterByPath[path] { added.append(PrimRef(path: path, typeName: prim.typeName)) }
        }
        for path in beforePaths.subtracting(afterPaths).sorted() {
            if let prim = beforeByPath[path] { removed.append(PrimRef(path: path, typeName: prim.typeName)) }
        }
        for path in beforePaths.intersection(afterPaths).sorted() {
            if let before = beforeByPath[path], let after = afterByPath[path] {
                let changes = primChanges(before, after)
                if !changes.isEmpty { changed.append(PrimDiff(path: path, changes: changes)) }
            }
        }

        var result = self
        result.addedPrims = added
        result.removedPrims = removed
        result.changedPrims = changed
        return result
    }

    // MARK: - Metadata comparison

    private static func metadataChanges(_ before: StageMetadata, _ after: StageMetadata) -> [ValueChange] {
        var changes: [ValueChange] = []
        func scalar(_ label: String, _ a: String?, _ b: String?) {
            if a != b { changes.append(ValueChange(label: label, before: a, after: b)) }
        }
        scalar("upAxis", before.upAxis.rawValue, after.upAxis.rawValue)
        scalar("metersPerUnit", number(before.metersPerUnit), number(after.metersPerUnit))
        scalar("defaultPrim", before.defaultPrim, after.defaultPrim)
        scalar("timeCodesPerSecond", before.timeCodesPerSecond.map(number), after.timeCodesPerSecond.map(number))
        scalar("startTimeCode", before.startTimeCode.map(number), after.startTimeCode.map(number))
        scalar("endTimeCode", before.endTimeCode.map(number), after.endTimeCode.map(number))
        changes.append(contentsOf: keyedChanges("customLayerData:", before.customLayerData, after.customLayerData))
        return changes
    }

    // MARK: - Prim comparison (shallow: this prim's own fields only)

    private func primChanges(_ before: Prim, _ after: Prim) -> [ValueChange] {
        var changes: [ValueChange] = []
        if before.typeName != after.typeName {
            changes.append(ValueChange(label: "type", before: before.typeName, after: after.typeName))
        }
        if before.isActive != after.isActive {
            changes.append(ValueChange(label: "active", before: String(before.isActive), after: String(after.isActive)))
        }
        if before.visibility != after.visibility {
            changes.append(ValueChange(label: "visibility",
                                       before: before.visibility.rawValue,
                                       after: after.visibility.rawValue))
        }
        changes.append(contentsOf: StageDiff.keyedChanges(
            "attr:",
            Dictionary(before.attributes.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(after.attributes.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first })))
        changes.append(contentsOf: StageDiff.keyedChanges(
            "rel:",
            Dictionary(before.relationships.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(after.relationships.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first })))
        changes.append(contentsOf: StageDiff.keyedChanges("meta:", before.metadata, after.metadata))
        changes.append(contentsOf: StageDiff.keyedChanges(
            "variantSet:",
            Dictionary(before.variantSets.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(after.variantSets.map { ($0.name, StageDiff.describe($0)) }, uniquingKeysWith: { first, _ in first })))
        return changes
    }

    // MARK: - Keyed (name → description) diff

    /// Emits a `ValueChange` for every key whose description differs between the
    /// two maps. Keys are visited in sorted order so output is deterministic.
    private static func keyedChanges(
        _ prefix: String,
        _ before: [String: String],
        _ after: [String: String]
    ) -> [ValueChange] {
        var out: [ValueChange] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            let b = before[key], a = after[key]
            if b != a { out.append(ValueChange(label: prefix + key, before: b, after: a)) }
        }
        return out
    }

    // MARK: - Descriptions

    /// Compact one-line description of an attribute that captures *every* field
    /// the diff compares — value, `uniform` qualifier, attribute metadata, and
    /// time samples — so any `Attribute` inequality is reflected in the string.
    static func describe(_ attribute: Attribute) -> String {
        var parts: [String] = []
        if attribute.isUniform { parts.append("uniform") }
        parts.append(attribute.value.typeLabel)
        parts.append("= \(describe(attribute.value))")
        if !attribute.metadata.isEmpty {
            let meta = attribute.metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("(\(meta))")
        }
        if let samples = attribute.timeSamples {
            let body = samples.map { "\(number($0.time)): \(describe($0.value))" }.joined(separator: ", ")
            parts.append("{\(body)}")
        }
        return parts.joined(separator: " ")
    }

    /// Compact description of a relationship's targets.
    static func describe(_ relationship: Relationship) -> String {
        let targets = relationship.targets.map(\.description).joined(separator: ", ")
        return (relationship.isUniform ? "uniform " : "") + "[\(targets)]"
    }

    /// Compact description of a variant set (`variants` + current `selection`).
    static func describe(_ variantSet: VariantSet) -> String {
        let variants = variantSet.variants.joined(separator: ", ")
        return "{\(variants)} = \(variantSet.selection ?? "∅")"
    }

    /// String form of an attribute value used in change descriptions.
    static func describe(_ value: AttributeValue) -> String {
        switch value {
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .double(let d): return number(d)
        case .string(let s): return "\"\(s)\""
        case .token(let t): return t
        case .asset(let a): return "@\(a)@"
        case .vector(let v): return "(" + v.map(number).joined(separator: ", ") + ")"
        case .matrix4(let m): return "[" + m.map(number).joined(separator: ", ") + "]"
        case .intArray(let a): return "[" + a.map(String.init).joined(separator: ", ") + "]"
        case .doubleArray(let a): return "[" + a.map(number).joined(separator: ", ") + "]"
        case .stringArray(let a): return "[" + a.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        case .tokenArray(let a): return "[" + a.joined(separator: ", ") + "]"
        case .float3Array(let a): return "[" + a.map(number).joined(separator: ", ") + "]"
        case .quatfArray(let a): return "[" + a.map(number).joined(separator: ", ") + "]"
        case .matrix4dArray(let a): return "[" + a.map(number).joined(separator: ", ") + "]"
        case .unsupported(let t): return "<\(t)>"
        }
    }

    /// Formats a double without a trailing `.0` when it is integral, so
    /// `metersPerUnit` reads `1` not `1.0` and diffs stay tidy.
    static func number(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    // MARK: - Rendering

    /// A human-readable, deterministic text rendering of the diff, used by the
    /// `openusdz diff` CLI and any future textual surface. Absent sides render
    /// as `∅`.
    public func render() -> String {
        if isEmpty { return "stages are identical" }
        var lines: [String] = []

        func changeLine(_ change: ValueChange, indent: String) {
            lines.append("\(indent)~ \(change.label): \(change.before ?? "∅") → \(change.after ?? "∅")")
        }

        if !metadata.isEmpty {
            lines.append("Stage metadata (\(metadata.count)):")
            for change in metadata { changeLine(change, indent: "  ") }
        }
        if !addedPrims.isEmpty {
            lines.append("Added prims (\(addedPrims.count)):")
            for ref in addedPrims { lines.append("  + \(ref.path) (\(displayType(ref.typeName)))") }
        }
        if !removedPrims.isEmpty {
            lines.append("Removed prims (\(removedPrims.count)):")
            for ref in removedPrims { lines.append("  - \(ref.path) (\(displayType(ref.typeName)))") }
        }
        if !changedPrims.isEmpty {
            lines.append("Changed prims (\(changedPrims.count)):")
            for diff in changedPrims {
                lines.append("  \(diff.path)")
                for change in diff.changes { changeLine(change, indent: "    ") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Typeless prims (`typeName == ""`) render as `def`, matching `openusdz info`.
    private func displayType(_ typeName: String) -> String {
        typeName.isEmpty ? "def" : typeName
    }
}
