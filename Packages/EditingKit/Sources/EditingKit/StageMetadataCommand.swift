import USDCore

/// Author root-layer stage metadata — up-axis, meters-per-unit, default prim,
/// custom layer data (PRD §5.3 "Edit stage/root metadata"; the unit/axis fixer
/// commits through this too).
///
/// The prior metadata is captured at construction so undo restores it exactly.
public struct SetStageMetadataCommand: EditCommand {
    public let newMetadata: StageMetadata
    public let oldMetadata: StageMetadata

    public init(newMetadata: StageMetadata, oldMetadata: StageMetadata) {
        self.newMetadata = newMetadata
        self.oldMetadata = oldMetadata
    }

    public var label: String { "Edit Stage Metadata" }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setStageMetadata(newMetadata))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.setStageMetadata(oldMetadata))
    }
}
