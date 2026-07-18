import Foundation
import USDCore
import EditingKit
import MeshKit
import ViewportKit

// MARK: - Mesh edit mode (roadmap Phase 6; specs/mesh-editing.md §Editor Integration)

/// The component-level tools. Hotkeys follow Blender muscle memory:
/// E extrude, I inset, X delete, M merge, F fill.
public enum MeshTool: String, CaseIterable, Identifiable, Sendable {
    case extrude, inset, delete, merge, fill, bevel

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .extrude: return "Extrude"
        case .inset: return "Inset"
        case .delete: return "Delete"
        case .merge: return "Merge"
        case .fill: return "Fill Hole"
        case .bevel: return "Bevel"
        }
    }

    public var systemImage: String {
        switch self {
        case .extrude: return "square.3.layers.3d.top.filled"
        case .inset: return "square.inset.filled"
        case .delete: return "trash"
        case .merge: return "arrow.triangle.merge"
        case .fill: return "circle.grid.cross.fill"
        case .bevel: return "pentagon"
        }
    }

    public var hotkey: Character {
        switch self {
        case .extrude: return "e"
        case .inset: return "i"
        case .delete: return "x"
        case .merge: return "m"
        case .fill: return "f"
        case .bevel: return "b"
        }
    }
}

/// Vertex / edge / face sub-modes (1 / 2 / 3 keys).
public enum MeshComponentMode: String, CaseIterable, Identifiable, Sendable {
    case vertex, edge, face
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var systemImage: String {
        switch self {
        case .vertex: return "circle.grid.3x3.fill"
        case .edge: return "line.diagonal"
        case .face: return "square.fill"
        }
    }
}

/// Why edit mode can't start on a prim — surfaced as a diagnostic badge, never
/// a silent no-op (spec §Skinned/animated meshes).
public enum MeshEditAvailability: Equatable, Sendable {
    case available
    case notAMesh
    case missingGeometry
    case skinned

    public var refusalMessage: String? {
        switch self {
        case .available: return nil
        case .notAMesh: return "Select a Mesh prim to enter edit mode."
        case .missingGeometry: return "This mesh has no readable points/face arrays."
        case .skinned: return "Mesh has skeletal binding — mesh editing would break weights."
        }
    }
}

/// Live edit-mode state: the in-memory session plus UI state (active tool,
/// component sub-mode, current component selection, pending tool parameters).
public struct MeshEditState {
    public var session: MeshEditSession
    public var tool: MeshTool?
    public var mode: MeshComponentMode = .face
    public var componentSelection: ComponentSelection = .faces([])
    /// HUD face-picker position (authored order); `nil` = all faces.
    public var selectedFaceIndex: Int? = 0
    /// Live hover preview: highlight the face under the cursor before
    /// clicking, so you can see what an op would target. Toggleable.
    public var hoverPreviewEnabled: Bool = true
    /// The face currently under the cursor (viewport-reported); `nil` = none.
    public var hoveredFaceIndex: Int?
    /// Parameter HUD values.
    public var extrudeDistance: Double = 0.1
    public var insetFraction: Double = 0.2
    public var mergeDistance: Double = 0.001
    public var bevelWidth: Double = 0.05
    /// HUD edge-picker position (sorted edge order) for the Bevel tool.
    public var selectedEdgeIndex: Int = 0
    /// Most recent op refusal / diagnostic for the HUD.
    public var lastDiagnostic: String?
}

extension EditorDocument {

    // MARK: Availability

    /// Whether Tab can enter edit mode on `path`, with the refusal reason.
    public func meshEditAvailability(at path: PrimPath) -> MeshEditAvailability {
        guard let prim = snapshot.prim(at: path), prim.typeName == "Mesh" else { return .notAMesh }
        if prim.relationships.contains(where: { $0.name == "skel:skeleton" }) { return .skinned }
        guard Self.flatMesh(from: prim) != nil else { return .missingGeometry }
        return .available
    }

    // MARK: Enter / exit (Tab toggle)

    /// Enters edit mode on the mesh prim at `path`. Returns the refusal reason
    /// when unavailable (caller shows the badge).
    @discardableResult
    public func enterMeshEditMode(at path: PrimPath) -> MeshEditAvailability {
        let availability = meshEditAvailability(at: path)
        guard availability == .available,
              let prim = snapshot.prim(at: path),
              let flat = Self.flatMesh(from: prim),
              let session = try? MeshEditSession(path: path, flat: flat) else { return availability }
        var state = MeshEditState(session: session)
        // Viewport component picking isn't wired yet (Metal overlays are the
        // next Phase 6 checkbox), so default to the first face — ops work
        // immediately, and the HUD face-picker steps through the rest.
        if let first = session.mesh.faceOrder.first {
            state.componentSelection = .faces([first])
        }
        meshEdit = state
        return .available
    }

    /// HUD face-picker: select the face at `index` in authored order (clamped);
    /// pass `nil` to select every face.
    public func selectMeshFace(index: Int?) {
        guard var state = meshEdit else { return }
        let order = state.session.mesh.faceOrder
        guard !order.isEmpty else { return }
        if let index {
            let clamped = min(max(index, 0), order.count - 1)
            state.selectedFaceIndex = clamped
            state.componentSelection = .faces([order[clamped]])
        } else {
            state.selectedFaceIndex = nil
            state.componentSelection = .faces(Set(order))
        }
        state.lastDiagnostic = nil
        meshEdit = state
    }

    /// Sorted edge list backing the HUD edge-picker (deterministic order).
    public var meshEditEdges: [EdgeKey] {
        guard let state = meshEdit else { return [] }
        return state.session.mesh.edgeFaceMap.keys.sorted(by: <)
    }

    /// HUD edge-picker: select the edge at `index` in sorted order (clamped).
    public func selectMeshEdge(index: Int) {
        guard var state = meshEdit else { return }
        let edges = state.session.mesh.edgeFaceMap.keys.sorted(by: <)
        guard !edges.isEmpty else { return }
        let clamped = min(max(index, 0), edges.count - 1)
        state.selectedEdgeIndex = clamped
        state.componentSelection = .edges([edges[clamped]])
        state.lastDiagnostic = nil
        meshEdit = state
    }

    /// Leaves edit mode; `commit` flushes the session to the stage as one
    /// undoable `MeshEditCommand` (spec: flush on leaving edit mode).
    public func exitMeshEditMode(commit: Bool = true) {
        defer { meshEdit = nil }
        guard commit, let command = meshEdit?.session.commitCommand() else { return }
        if run(command) != nil { lastMeshEditPath = command.path }
    }

    /// Tab behavior: toggle against the current selection. When the selected
    /// prim isn't itself a Mesh (the common case for imported USDZ, where the
    /// user selects the model root and the Mesh sits under Xform scopes),
    /// descend to the first editable Mesh in its subtree. Refusals surface in
    /// `meshEditRefusal` — never a silent no-op.
    public func toggleMeshEditMode() {
        meshEditRefusal = nil
        if meshEdit != nil {
            exitMeshEditMode()
            return
        }
        guard let path = selection.paths.first else {
            meshEditRefusal = "Nothing selected — select a prim, then press ⇥."
            return
        }
        let target = editableMeshDescendant(from: path) ?? path
        let availability = enterMeshEditMode(at: target)
        if availability != .available {
            meshEditRefusal = availability.refusalMessage
        }
    }

    /// First prim at-or-below `path` (depth-first, authored order) on which
    /// edit mode can start; `nil` when the subtree has none.
    func editableMeshDescendant(from path: PrimPath) -> PrimPath? {
        guard let prim = snapshot.prim(at: path) else { return nil }
        if meshEditAvailability(at: prim.path) == .available { return prim.path }
        for child in prim.children {
            if let found = editableMeshDescendant(from: child.path) { return found }
        }
        return nil
    }

    // MARK: Tool application

    /// Runs the active tool against the current component selection, recording
    /// it in the session (one in-session undo step). Refusals surface in
    /// `meshEdit.lastDiagnostic` — loud, never silent.
    public func applyActiveMeshTool() {
        guard var state = meshEdit, let tool = state.tool else { return }
        let mesh = state.session.mesh
        do {
            let result: MeshOpResult
            let entry: String
            switch tool {
            case .extrude:
                result = try ExtrudeFaces.apply(mesh, selection: state.componentSelection,
                                                params: .init(distance: state.extrudeDistance))
                entry = "Extrude"
            case .inset:
                result = try InsetFaces.apply(mesh, selection: state.componentSelection,
                                              params: .init(fraction: state.insetFraction))
                entry = "Inset"
            case .delete:
                result = try DeleteComponents.apply(mesh, selection: state.componentSelection)
                entry = "Delete"
            case .merge:
                result = try MergeVertices.apply(mesh, selection: state.componentSelection,
                                                 params: .byDistance(state.mergeDistance))
                entry = "Merge"
            case .fill:
                result = try FillHole.apply(mesh, selection: state.componentSelection)
                entry = "Fill Hole"
            case .bevel:
                // Bevel targets edges; if the current selection is faces (the
                // default), resolve the HUD edge-picker choice instead.
                var selection = state.componentSelection
                if case .edges = selection {} else {
                    let edges = mesh.edgeFaceMap.keys.sorted(by: <)
                    guard !edges.isEmpty else { throw MeshOpError.emptySelection }
                    let clamped = min(max(state.selectedEdgeIndex, 0), edges.count - 1)
                    selection = .edges([edges[clamped]])
                }
                result = try BevelEdges.apply(mesh, selection: selection,
                                              params: .init(width: state.bevelWidth))
                entry = "Bevel"
            }
            state.session.record(result, journalEntry: entry)
            state.componentSelection = result.resultSelection
            state.lastDiagnostic = nil
        } catch let error as MeshOpError {
            state.lastDiagnostic = error.description
        } catch {
            state.lastDiagnostic = "\(error)"
        }
        meshEdit = state
    }

    public func undoMeshEdit() {
        guard var state = meshEdit, state.session.canUndo else { return }
        state.session.undo()
        state.componentSelection = .faces([])
        state.lastDiagnostic = nil
        meshEdit = state
    }

    // MARK: Viewport bridge

    /// The live edit-session geometry as viewport data (`nil` outside edit
    /// mode) — the viewport swaps the file-loaded model for this so edits are
    /// visible immediately, and clicks pick faces against it.
    public var viewportEditedMesh: ViewportKit.EditedMeshData? {
        guard let state = meshEdit else {
            // After a commit (or undo/redo of one), the stage — not the file —
            // is the source of truth for the last-edited mesh.
            guard let path = lastMeshEditPath, let prim = snapshot.prim(at: path),
                  let flat = Self.flatMesh(from: prim) else { return nil }
            return Self.editedMeshData(path: path, flat: flat,
                                       selectedFaces: [], revision: revision)
        }
        let mesh = state.session.mesh
        let flat = MeshIO.flat(from: mesh)
        let order = mesh.faceOrder
        var selected = Set<Int>()
        if case .faces(let faces) = state.componentSelection {
            for (i, f) in order.enumerated() where faces.contains(f) { selected.insert(i) }
        }
        return Self.editedMeshData(path: state.session.path, flat: flat,
                                   selectedFaces: selected,
                                   revision: state.session.journal.count &+ revision &+ selected.hashValue)
    }

    /// Viewport click → face selection (indices are authored order, matching
    /// the HUD face-picker). `additive` (⇧-click) toggles the face against the
    /// current selection instead of replacing it, so tools like Extrude and
    /// Inset can run on a group of faces at once.
    public func pickMeshFace(index: Int, additive: Bool = false) {
        guard additive else {
            selectMeshFace(index: index)
            return
        }
        guard var state = meshEdit else { return }
        let order = state.session.mesh.faceOrder
        guard order.indices.contains(index) else { return }
        let face = order[index]
        var faces: Set<FaceID>
        if case .faces(let current) = state.componentSelection {
            faces = current
        } else {
            faces = []
        }
        if faces.contains(face) { faces.remove(face) } else { faces.insert(face) }
        state.componentSelection = .faces(faces)
        // Keep the HUD stepper anchored to a single-face selection; a
        // multi-face (or empty) set has no meaningful stepper position.
        state.selectedFaceIndex = faces.count == 1
            ? faces.first.flatMap { order.firstIndex(of: $0) } : nil
        state.lastDiagnostic = nil
        meshEdit = state
    }

    /// Number of faces in the current component selection (0 outside face
    /// selection) — drives the HUD "N faces" readout.
    public var meshEditSelectedFaceCount: Int {
        guard let state = meshEdit, case .faces(let faces) = state.componentSelection else { return 0 }
        return faces.count
    }

    /// Viewport hover → HUD readout ("will extrude Face n").
    public func hoverMeshFace(index: Int?) {
        guard meshEdit != nil, meshEdit?.hoveredFaceIndex != index else { return }
        meshEdit?.hoveredFaceIndex = index
    }

    private static func editedMeshData(
        path: PrimPath, flat: FlatMesh, selectedFaces: Set<Int>, revision: Int
    ) -> ViewportKit.EditedMeshData {
        var loops: [[Int]] = []
        var cursor = 0
        for count in flat.faceVertexCounts {
            loops.append(Array(flat.faceVertexIndices[cursor..<(cursor + count)]))
            cursor += count
        }
        return ViewportKit.EditedMeshData(
            primName: path.name,
            primPath: path.description,
            positions: flat.points.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) },
            faceLoops: loops,
            selectedFaces: selectedFaces,
            revision: revision)
    }

    // MARK: Flat-array extraction

    /// Reads UsdGeomMesh flat arrays off a snapshot prim; `nil` when the prim
    /// doesn't carry complete geometry.
    static func flatMesh(from prim: Prim) -> FlatMesh? {
        guard case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value,
              case .intArray(let indices)? = prim.attribute(named: "faceVertexIndices")?.value,
              let raw = prim.attribute(named: "points")?.value else { return nil }
        let flatPoints: [Double]
        switch raw {
        case .float3Array(let d), .doubleArray(let d): flatPoints = d
        default: return nil
        }
        guard flatPoints.count % 3 == 0 else { return nil }
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(flatPoints.count / 3)
        for i in stride(from: 0, to: flatPoints.count, by: 3) {
            points.append(SIMD3(flatPoints[i], flatPoints[i + 1], flatPoints[i + 2]))
        }
        var uvs: [SIMD2<Double>] = []
        if case .doubleArray(let st)? = prim.attribute(named: "primvars:st")?.value,
           st.count % 2 == 0, st.count / 2 == indices.count {
            for i in stride(from: 0, to: st.count, by: 2) { uvs.append(SIMD2(st[i], st[i + 1])) }
        }
        let skinned = prim.relationships.contains { $0.name == "skel:skeleton" }
        return FlatMesh(points: points, faceVertexCounts: counts, faceVertexIndices: indices,
                        faceVaryingUVs: uvs, hasSkeletalBinding: skinned)
    }
}
