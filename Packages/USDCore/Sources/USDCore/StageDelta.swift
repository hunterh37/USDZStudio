import Foundation

/// A structural, human-readable diff between two USD stages.
///
/// Where `AgentMCP.StageDiff` exists to tell a coding agent *what one command
/// changed* during a live edit session (before/after snapshots of a single
/// stage), `StageDelta` is the editor-wide, file-oriented comparison: point it
/// at two independently-opened stages — two files, or the same file before and
/// after an edit batch — and it reports the added / removed / changed prims,
/// which facets of each changed prim moved, and which root-metadata fields
/// differ. Pure value logic over `USDStageProtocol`, so it composes with the
/// snapshot the bridge produces, the CLI `diff` subcommand, and (later) a diff
/// panel, without any of them importing each other.
///
/// Prims are matched by absolute path — the stable identity USD itself uses.
/// A rename therefore reads as one removed path + one added path, which is the
/// truthful structural account (the editor's own `RenamePrimCommand` reparents
/// the subtree to a new path, so its identity genuinely changes).
public struct StageDelta: Sendable, Hashable {

    /// How a single named attribute moved between the two prims at one path.
    public struct AttributeChange: Sendable, Hashable, Comparable {
        public enum Kind: String, Sendable, Hashable {
            case added, removed, modified
        }
        public var name: String
        public var kind: Kind

        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        /// Sorted by name so a report is deterministic and diff-stable.
        public static func < (lhs: AttributeChange, rhs: AttributeChange) -> Bool {
            lhs.name < rhs.name
        }
    }

    /// A prim present in both stages whose content differs. Only the facets that
    /// actually moved are flagged, so a report can name them precisely
    /// ("type + 2 attributes") rather than just "changed".
    public struct PrimChange: Sendable, Hashable, Comparable {
        public var path: PrimPath
        public var typeChanged: Bool
        public var activationChanged: Bool
        public var visibilityChanged: Bool
        public var relationshipsChanged: Bool
        public var metadataChanged: Bool
        public var variantSetsChanged: Bool
        public var attributeChanges: [AttributeChange]

        public init(
            path: PrimPath,
            typeChanged: Bool = false,
            activationChanged: Bool = false,
            visibilityChanged: Bool = false,
            relationshipsChanged: Bool = false,
            metadataChanged: Bool = false,
            variantSetsChanged: Bool = false,
            attributeChanges: [AttributeChange] = []
        ) {
            self.path = path
            self.typeChanged = typeChanged
            self.activationChanged = activationChanged
            self.visibilityChanged = visibilityChanged
            self.relationshipsChanged = relationshipsChanged
            self.metadataChanged = metadataChanged
            self.variantSetsChanged = variantSetsChanged
            self.attributeChanges = attributeChanges
        }

        /// Short, human-facing list of the facets that changed on this prim,
        /// e.g. `["type", "visibility", "attributes(2)"]`.
        public var changedFacets: [String] {
            var facets: [String] = []
            if typeChanged { facets.append("type") }
            if activationChanged { facets.append("active") }
            if visibilityChanged { facets.append("visibility") }
            if relationshipsChanged { facets.append("relationships") }
            if metadataChanged { facets.append("metadata") }
            if variantSetsChanged { facets.append("variants") }
            if !attributeChanges.isEmpty { facets.append("attributes(\(attributeChanges.count))") }
            return facets
        }

        public static func < (lhs: PrimChange, rhs: PrimChange) -> Bool {
            lhs.path < rhs.path
        }
    }

    /// Paths present only in the *after* stage.
    public var addedPrims: [PrimPath]
    /// Paths present only in the *before* stage.
    public var removedPrims: [PrimPath]
    /// Paths present in both whose content differs.
    public var changedPrims: [PrimChange]
    /// Names of the `StageMetadata` fields that differ (sorted); empty when the
    /// root metadata is identical.
    public var changedMetadataFields: [String]

    public init(
        addedPrims: [PrimPath] = [],
        removedPrims: [PrimPath] = [],
        changedPrims: [PrimChange] = [],
        changedMetadataFields: [String] = []
    ) {
        self.addedPrims = addedPrims
        self.removedPrims = removedPrims
        self.changedPrims = changedPrims
        self.changedMetadataFields = changedMetadataFields
    }

    /// `true` when the two stages are structurally identical.
    public var isEmpty: Bool {
        addedPrims.isEmpty && removedPrims.isEmpty
            && changedPrims.isEmpty && changedMetadataFields.isEmpty
    }

    /// Total number of prim-level differences (added + removed + changed).
    public var changeCount: Int {
        addedPrims.count + removedPrims.count + changedPrims.count
    }

    // MARK: - Compute

    /// Compare two stages, matching prims by absolute path.
    public static func compute(
        before: any USDStageProtocol,
        after: any USDStageProtocol
    ) -> StageDelta {
        let beforeMap = index(before)
        let afterMap = index(after)

        let added = afterMap.keys.filter { beforeMap[$0] == nil }.sorted()
        let removed = beforeMap.keys.filter { afterMap[$0] == nil }.sorted()

        var changes: [PrimChange] = []
        for (path, old) in beforeMap {
            guard let new = afterMap[path] else { continue }
            if let change = primChange(path: path, old: old, new: new) {
                changes.append(change)
            }
        }
        changes.sort()

        return StageDelta(
            addedPrims: added,
            removedPrims: removed,
            changedPrims: changes,
            changedMetadataFields: metadataFieldChanges(before.metadata, after.metadata))
    }

    // MARK: - Rendering

    /// Deterministic, human-readable report lines. Empty stage-identical input
    /// yields a single "no differences" line so callers always print something.
    public func summaryLines() -> [String] {
        guard !isEmpty else { return ["no differences"] }
        var lines: [String] = []
        for path in addedPrims { lines.append("+ \(path)") }
        for path in removedPrims { lines.append("- \(path)") }
        for change in changedPrims {
            lines.append("~ \(change.path) [\(change.changedFacets.joined(separator: ", "))]")
            for attribute in change.attributeChanges {
                lines.append("    \(Self.symbol(attribute.kind)) \(attribute.name)")
            }
        }
        if !changedMetadataFields.isEmpty {
            lines.append("~ <stage metadata> [\(changedMetadataFields.joined(separator: ", "))]")
        }
        return lines
    }

    // MARK: - Internals

    private static func symbol(_ kind: AttributeChange.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .modified: return "~"
        }
    }

    private static func index(_ stage: any USDStageProtocol) -> [PrimPath: Prim] {
        var map: [PrimPath: Prim] = [:]
        for prim in stage.allPrims() { map[prim.path] = prim }
        return map
    }

    /// `nil` when the two prims (ignoring children — child changes surface at
    /// their own paths) are equivalent.
    private static func primChange(path: PrimPath, old: Prim, new: Prim) -> PrimChange? {
        let attributeChanges = attributeChanges(old: old.attributes, new: new.attributes)
        let change = PrimChange(
            path: path,
            typeChanged: old.typeName != new.typeName,
            activationChanged: old.isActive != new.isActive,
            visibilityChanged: old.visibility != new.visibility,
            relationshipsChanged: old.relationships != new.relationships,
            metadataChanged: old.metadata != new.metadata,
            variantSetsChanged: old.variantSets != new.variantSets,
            attributeChanges: attributeChanges)
        return change.changedFacets.isEmpty ? nil : change
    }

    private static func attributeChanges(old: [Attribute], new: [Attribute]) -> [AttributeChange] {
        let oldByName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let newByName = Dictionary(new.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [AttributeChange] = []
        for (name, attribute) in newByName {
            if let previous = oldByName[name] {
                if previous != attribute { changes.append(AttributeChange(name: name, kind: .modified)) }
            } else {
                changes.append(AttributeChange(name: name, kind: .added))
            }
        }
        for name in oldByName.keys where newByName[name] == nil {
            changes.append(AttributeChange(name: name, kind: .removed))
        }
        return changes.sorted()
    }

    private static func metadataFieldChanges(_ old: StageMetadata, _ new: StageMetadata) -> [String] {
        var fields: [String] = []
        if old.upAxis != new.upAxis { fields.append("upAxis") }
        if old.metersPerUnit != new.metersPerUnit { fields.append("metersPerUnit") }
        if old.defaultPrim != new.defaultPrim { fields.append("defaultPrim") }
        if old.customLayerData != new.customLayerData { fields.append("customLayerData") }
        if old.timeCodesPerSecond != new.timeCodesPerSecond { fields.append("timeCodesPerSecond") }
        if old.startTimeCode != new.startTimeCode { fields.append("startTimeCode") }
        if old.endTimeCode != new.endTimeCode { fields.append("endTimeCode") }
        return fields
    }
}
