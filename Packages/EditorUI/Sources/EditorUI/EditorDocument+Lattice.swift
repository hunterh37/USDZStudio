import Foundation
import USDCore
import MeshKit
import EditingKit
import ViewportKit

/// Live lattice (FFD) deform state (specs/mesh-editing.md §Lattice deformer;
/// research/topics/lattice-deformer). The cage is expressed in the target
/// prim's **local** space — the same space its `points` are authored in, and the
/// space the prim-local viewport ray operates in — so no world-matrix math is
/// needed here and the bake maps straight onto the mesh.
public struct LatticeEditState: Sendable, Equatable {
    public var path: PrimPath
    /// The current (edited) cage.
    public var cage: LatticeCage
    /// The rest cage, preserved for Reset and to detect "no change on exit".
    public var restCage: LatticeCage
    /// Selected control-point handle indices (the drag target set).
    public var selectedHandles: Set<Int>
    /// Bumped on every mutation so the viewport re-lays-out in lockstep.
    public var revision: Int
    /// Control-point snapshot frozen at drag start, so a multi-handle drag
    /// applies the delta relative to grab positions (not accumulating per frame).
    public var dragStart: [SIMD3<Double>]?

    public init(path: PrimPath, cage: LatticeCage, selectedHandles: Set<Int> = [], revision: Int = 0,
                dragStart: [SIMD3<Double>]? = nil) {
        self.dragStart = dragStart
        self.path = path
        self.cage = cage
        self.restCage = cage
        self.selectedHandles = selectedHandles
        self.revision = revision
    }

    /// True once any control point has moved from its rest position.
    public var isDeformed: Bool { cage.controlPoints != restCage.controlPoints }
}

extension EditorDocument {

    // MARK: Enter / exit

    /// Enters lattice mode on the mesh prim at `path`, fitting a rest cage to its
    /// local-space bounds. Returns the refusal reason when unavailable (reusing
    /// the mesh-edit availability rules: must be an unskinned mesh with geometry).
    @discardableResult
    public func enterLatticeMode(at path: PrimPath) -> MeshEditAvailability {
        let availability = meshEditAvailability(at: path)
        guard availability == .available,
              let prim = snapshot.prim(at: path),
              let flat = Self.flatMesh(from: prim),
              let cage = Self.fittedCage(for: flat.points) else { return availability }
        latticeEdit = LatticeEditState(path: path, cage: cage)
        latticeRefusal = nil
        return .available
    }

    /// Toggle lattice mode against the current selection (descending to the first
    /// editable mesh, like the Tab handler). Refusals land in `latticeRefusal`.
    public func toggleLatticeMode() {
        latticeRefusal = nil
        if latticeEdit != nil { exitLatticeMode(); return }
        guard let path = selection.paths.first else {
            latticeRefusal = "Nothing selected — select a mesh, then start the lattice tool."
            return
        }
        let target = editableMeshDescendant(from: path) ?? path
        let availability = enterLatticeMode(at: target)
        if availability != .available { latticeRefusal = availability.refusalMessage }
    }

    /// Leaves lattice mode; `commit` bakes the deformation as one undoable
    /// `LatticeDeformCommand` — but only when the cage actually moved.
    public func exitLatticeMode(commit: Bool = true) {
        defer { latticeEdit = nil }
        guard commit, let state = latticeEdit, state.isDeformed,
              let command = try? LatticeDeformCommand.make(path: state.path,
                                                           cage: state.cage, in: snapshot)
        else { return }
        if run(command) != nil { lastMeshEditPath = state.path }
    }

    // MARK: Panel controls

    /// Set the per-axis resolution, refitting the cage to the same rest bounds.
    /// Values are clamped to `[2, LatticeCage.maxPerAxis]`. Because the grid
    /// topology changes, any in-progress deformation resets (Blender parity).
    public func setLatticeResolution(l: Int, m: Int, n: Int) {
        guard var state = latticeEdit else { return }
        func clamp(_ v: Int) -> Int { min(max(v, 2), LatticeCage.maxPerAxis) }
        let rest = state.restCage
        let cage = LatticeCage(origin: rest.origin, edgeS: rest.edgeS, edgeT: rest.edgeT,
                               edgeU: rest.edgeU,
                               resolution: .init(l: clamp(l), m: clamp(m), n: clamp(n)),
                               interpolation: rest.interpolation, affectOutside: rest.affectOutside)
        state.cage = cage
        state.restCage = cage
        state.selectedHandles = []
        state.revision += 1
        latticeEdit = state
    }

    /// Switch the interpolation basis, preserving control-point positions.
    public func setLatticeInterpolation(_ interpolation: LatticeCage.Interpolation) {
        mutateLattice { $0.cage.interpolation = interpolation; $0.restCage.interpolation = interpolation }
    }

    /// Toggle whether geometry outside the cage is deformed too.
    public func setLatticeAffectOutside(_ affect: Bool) {
        mutateLattice { $0.cage.affectOutside = affect; $0.restCage.affectOutside = affect }
    }

    /// Restore every control point to its rest position.
    public func resetLattice() {
        mutateLattice { $0.cage = $0.restCage; $0.selectedHandles = [] }
    }

    private func mutateLattice(_ body: (inout LatticeEditState) -> Void) {
        guard var state = latticeEdit else { return }
        body(&state)
        state.revision += 1
        latticeEdit = state
    }

    // MARK: Viewport gizmo

    /// Descriptor the viewport renders (control-point handles + wireframe),
    /// `nil` outside lattice mode.
    public var latticeCageGizmo: LatticeCageGizmoDescriptor? {
        guard let state = latticeEdit else { return nil }
        return LatticeCageGizmoDescriptor(controlPoints: state.cage.controlPoints,
                                          resolution: state.cage.resolution,
                                          selected: state.selectedHandles,
                                          revision: state.revision)
    }

    /// Handle a control-point drag from the viewport. `.began` selects the
    /// grabbed handle; `.changed` translates every selected handle by the
    /// local-space delta (so multi-select moves rigidly); `.ended` is a no-op
    /// (commit happens on exit).
    public func handleLatticeCageDrag(_ phase: LatticeCageGizmoDragPhase) {
        guard var state = latticeEdit else { return }
        switch phase {
        case .began(let handle):
            if !state.selectedHandles.contains(handle) { state.selectedHandles = [handle] }
            state.dragStart = state.cage.controlPoints
        case .changed(let handle, let delta):
            let targets = state.selectedHandles.isEmpty ? [handle] : state.selectedHandles
            let base = state.dragStart ?? state.cage.controlPoints
            var cps = base
            for i in targets where i >= 0 && i < cps.count { cps[i] = base[i] + delta }
            state.cage.controlPoints = cps
        case .ended:
            state.dragStart = nil
        }
        state.revision += 1
        latticeEdit = state
    }

    // MARK: Bounds fitting

    /// A rest cage fitted to a point cloud's axis-aligned bounds, padded so the
    /// geometry sits strictly inside. `nil` for an empty/degenerate cloud.
    static func fittedCage(for points: [SIMD3<Double>]) -> LatticeCage? {
        guard let first = points.first else { return nil }
        var lo = first, hi = first
        for p in points {
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        // Pad each axis by 5% of its extent (a floor of 0.01 for flat axes) so no
        // vertex lands exactly on a cage face.
        func pad(_ a: Double, _ b: Double) -> (Double, Double) {
            let m = max((b - a) * 0.05, 0.01)
            return (a - m, b + m)
        }
        let (x0, x1) = pad(lo.x, hi.x)
        let (y0, y1) = pad(lo.y, hi.y)
        let (z0, z1) = pad(lo.z, hi.z)
        return LatticeCage.fitted(min: SIMD3(x0, y0, z0), max: SIMD3(x1, y1, z1),
                                  resolution: .default, interpolation: .trilinear)
    }
}
