import Foundation
import USDCore

/// What a left-mouse-down in the viewport hit, as resolved by picking.
public enum ViewportHit: Equatable, Sendable {
    /// A transform gizmo handle (translate arrow, rotate ring, scale box…).
    case handle
    /// A prim's mesh body at the given path.
    case prim(PrimPath)
    /// Empty space (no gizmo, no geometry).
    case empty
}

/// Modifier keys / buttons held at mouse-down that steer disambiguation.
public struct DragModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The "camera in any mode" escape hatch (Space held, or a middle-drag):
    /// forces orbit even when the press lands on the selected body.
    public static let camera = DragModifiers(rawValue: 1 << 0)

    public static let none: DragModifiers = []
}

/// What a resolved left-drag should do.
public enum DragIntent: Equatable, Sendable {
    /// The active handle gizmo claims the drag (unchanged Maya path).
    case gizmoHandle
    /// Start an unconstrained modal grab of the selected body (body-drag).
    case bodyGrab
    /// Rubber-band marquee selection (box-select, when enabled).
    case boxSelect
    /// Orbit the camera.
    case cameraOrbit
}

/// The pure priority policy that resolves a viewport left-mouse-down into a
/// `DragIntent`. First match wins (see `plan.md` §Left-drag disambiguation):
///
///   1. On a gizmo handle → the handle claims the drag.
///   2. Camera modifier held → orbit (the escape hatch, even on-body).
///   3. On the selected prim's body → body-grab.
///   4. Otherwise → marquee if box-select is enabled, else orbit.
///
/// Deliberately an `NSView`-free pure function so it is exhaustively unit-tested
/// over the hit × selection × modifier × box-select matrix.
public enum ViewportDragRouter {

    public static func resolve(hit: ViewportHit,
                               selection: Set<PrimPath>,
                               modifiers: DragModifiers,
                               boxSelectEnabled: Bool) -> DragIntent {
        // 1. A handle grab always wins — the active gizmo owns the whole gesture.
        if hit == .handle { return .gizmoHandle }

        // 2. The camera modifier forces orbit regardless of what's under it.
        if modifiers.contains(.camera) { return .cameraOrbit }

        // 3. A press on the currently-selected body starts a modal grab.
        if case let .prim(path) = hit, selection.contains(path) { return .bodyGrab }

        // 4. Empty space or a non-selected prim: marquee when enabled, else orbit.
        return boxSelectEnabled ? .boxSelect : .cameraOrbit
    }
}
