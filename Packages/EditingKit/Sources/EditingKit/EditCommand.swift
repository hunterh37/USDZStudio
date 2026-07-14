import USDCore

/// Command-pattern edit layer (specs/editing-model.md; full implementation is
/// Phase 3). The protocol lands in Phase 0 so scripting, undo, and future
/// collaboration build on a stable seam from day one.
public protocol EditCommand: Sendable {
    /// Shown in Edit ▸ Undo <label>.
    var label: String { get }
    func execute(on stage: any USDStageMutable) throws
    func undo(on stage: any USDStageMutable) throws
}

/// A minimal, fully-implemented command: toggling prim visibility.
/// (Hide semantics — the part ships in the file; PRD §5.3.)
public struct SetVisibilityCommand: EditCommand {
    public let path: PrimPath
    public let newVisibility: Visibility
    public let oldVisibility: Visibility

    public init(path: PrimPath, newVisibility: Visibility, oldVisibility: Visibility) {
        self.path = path
        self.newVisibility = newVisibility
        self.oldVisibility = oldVisibility
    }

    public var label: String {
        newVisibility == .invisible ? "Hide \(path.name)" : "Show \(path.name)"
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.setVisibility(path: path, visibility: newVisibility))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.setVisibility(path: path, visibility: oldVisibility))
    }
}
