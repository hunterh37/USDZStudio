import Foundation

/// Stage up-axis. RealityKit expects Y-up output; Z-up input is surfaced so
/// the unit/axis fixer can correct it (PRD §5.3).
public enum UpAxis: String, Hashable, Sendable, Codable {
    case y = "Y"
    case z = "Z"
}

/// Root-layer metadata (PRD §5.3 "Edit stage/root metadata").
public struct StageMetadata: Hashable, Sendable, Codable {
    public var upAxis: UpAxis
    public var metersPerUnit: Double
    public var defaultPrim: String?
    public var customLayerData: [String: String]
    /// Playback rate; `nil` when the stage carries no animation. When set, the
    /// transport bar (specs/viewport.md) honours it.
    public var timeCodesPerSecond: Double?
    /// Inclusive animation time-code range; `nil` on a static stage.
    public var startTimeCode: Double?
    public var endTimeCode: Double?

    public init(
        upAxis: UpAxis = .y,
        metersPerUnit: Double = 1.0,
        defaultPrim: String? = nil,
        customLayerData: [String: String] = [:],
        timeCodesPerSecond: Double? = nil,
        startTimeCode: Double? = nil,
        endTimeCode: Double? = nil
    ) {
        self.upAxis = upAxis
        self.metersPerUnit = metersPerUnit
        self.defaultPrim = defaultPrim
        self.customLayerData = customLayerData
        self.timeCodesPerSecond = timeCodesPerSecond
        self.startTimeCode = startTimeCode
        self.endTimeCode = endTimeCode
    }

    /// `true` when the stage declares an animation time range.
    public var isAnimated: Bool { startTimeCode != nil && endTimeCode != nil }
}

/// Read-only view of a USD stage — the seam between USDBridge (the only
/// module that talks to Python/usd-core) and everything downstream.
public protocol USDStageProtocol: Sendable {
    var sourceURL: URL? { get }
    var metadata: StageMetadata { get }
    var rootPrims: [Prim] { get }

    /// Depth-first list of every prim on the stage.
    ///
    /// A protocol *requirement* rather than a plain extension method so that a
    /// conformer holding a precomputed traversal — see `IndexedStage` — actually
    /// gets called through dynamic dispatch instead of being bypassed by the
    /// statically-dispatched default below.
    func allPrims() -> [Prim]

    /// Looks up a prim by absolute path. A requirement for the same reason.
    func prim(at path: PrimPath) -> Prim?
}

extension USDStageProtocol {
    public func allPrims() -> [Prim] {
        var result: [Prim] = []
        for root in rootPrims { result.append(contentsOf: root.flattened()) }
        return result
    }

    /// Total prim count.
    public var primCount: Int { allPrims().count }

    public func prim(at path: PrimPath) -> Prim? {
        for root in rootPrims {
            if let found = root.prim(at: path) { return found }
        }
        return nil
    }

    /// All prims whose name matches `name` exactly.
    public func prims(named name: String) -> [Prim] {
        allPrims().filter { $0.name == name }
    }
}

/// An immutable, value-typed stage snapshot. USDBridge produces these; the
/// outliner, inspector, and viewport consume them.
public struct StageSnapshot: USDStageProtocol, Hashable, Codable {
    public var sourceURL: URL?
    public var metadata: StageMetadata
    public var rootPrims: [Prim]

    public init(sourceURL: URL? = nil, metadata: StageMetadata = StageMetadata(), rootPrims: [Prim] = []) {
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.rootPrims = rootPrims
    }
}

/// Mutation seam for EditingKit commands (Phase 3). Declared here so the
/// command protocol can compile against USDCore without importing the bridge.
public protocol USDStageMutable: USDStageProtocol {
    func apply(_ mutation: StageMutation) throws
}

/// The closed set of stage mutations the editor authors (Phase 3 scope;
/// enumerated now so the command layer has a stable vocabulary).
public enum StageMutation: Hashable, Sendable, Codable {
    case setAttribute(path: PrimPath, attribute: Attribute)
    /// Removes the named attribute from the prim at `path`. Absent attributes are
    /// tolerated (idempotent), so this is the clean inverse of `setAttribute` when
    /// the attribute did not exist beforehand.
    case removeAttribute(path: PrimPath, name: String)
    case setVisibility(path: PrimPath, visibility: Visibility)
    case setActive(path: PrimPath, isActive: Bool)
    case renamePrim(path: PrimPath, newName: String)
    case removePrim(path: PrimPath)
    /// Inserts `prim` as a child of `parent` (root when `nil`) at `index`,
    /// clamped into range. The inverse of `removePrim`, so deletes are undoable.
    case insertPrim(parent: PrimPath?, index: Int, prim: Prim)
    case setStageMetadata(StageMetadata)
    /// Selects `selection` (or clears it when `nil`) in the named variant set on
    /// the prim at `path`. The classic "swap the red variant for blue" edit.
    case setVariantSelection(path: PrimPath, setName: String, selection: String?)
}
