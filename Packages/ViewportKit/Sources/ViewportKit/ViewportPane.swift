#if os(macOS)
import SwiftUI
import RealityKit
import AppKit

/// The Phase 1 viewport (specs/viewport.md): RealityKit fast-path loading
/// via `Entity(contentsOf:)`, turntable orbit / pan / dolly, `F` frame,
/// grid + axes, stats HUD. GPU/AppKit glue lives here by design; the math it
/// drives (OrbitCamera, GridModel, SceneStats) is unit-tested separately.
// coverage:disable — RealityKit/AppKit rendering glue, verified by golden-image tests (specs/testing.md layer 6)

/// Which camera action a plain left-drag performs. Selectable from the
/// three-button control in the viewport's top-leading corner; modifier-key and
/// scroll-wheel shortcuts keep working regardless of the active mode.
public enum CameraInteractionMode: String, CaseIterable, Identifiable {
    case rotate, zoom, pan

    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rotate: "rotate.3d"
        case .zoom: "plus.magnifyingglass"
        case .pan: "hand.draw"
        }
    }

    var label: String { rawValue.capitalized }

    /// Tooltip naming the always-on shortcuts alongside the mode, in the
    /// standard CAD "action (modifier)" tooltip form.
    var helpText: String {
        switch self {
        case .rotate: "Rotate — drag to orbit"
        case .zoom: "Zoom — drag or scroll to dolly"
        case .pan: "Pan — drag (or ⇧-drag / middle-drag in any mode)"
        }
    }
}

public struct ViewportPane: View {

    let modelURL: URL?
    /// Live component-edit geometry replacing the file-loaded model for one
    /// prim (Phase 6). `nil` = plain file rendering.
    let editedMesh: EditedMeshData?
    /// Called with the picked face index (authored order) on a click while
    /// `editedMesh` is active. The second parameter is `true` when ⇧ was held
    /// (additive selection: toggle the face into/out of the current set).
    let onPickFace: ((Int, Bool) -> Void)?
    /// Live hover preview: highlight the face under the cursor (the one a
    /// click / op would target). Reported up so the HUD can name it.
    let hoverPreview: Bool
    let onHoverFace: ((Int?) -> Void)?
    @State private var stats: SceneStats?
    @State private var showStats = true
    @State private var loadError: String?
    @State private var cameraMode: CameraInteractionMode = .rotate

    public init(modelURL: URL?,
                editedMesh: EditedMeshData? = nil,
                onPickFace: ((Int, Bool) -> Void)? = nil,
                hoverPreview: Bool = false,
                onHoverFace: ((Int?) -> Void)? = nil) {
        self.modelURL = modelURL
        self.editedMesh = editedMesh
        self.onPickFace = onPickFace
        self.hoverPreview = hoverPreview
        self.onHoverFace = onHoverFace
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewportRepresentable(modelURL: modelURL, mode: cameraMode,
                                  editedMesh: editedMesh, onPickFace: onPickFace,
                                  hoverPreview: hoverPreview, onHoverFace: onHoverFace,
                                  stats: $stats, loadError: $loadError)
            cameraModeControl
            if showStats, let stats {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(stats.countsLine)
                    Text(stats.boundsLine)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
            }
            if let loadError {
                Text(loadError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// Three-button camera-mode toggle, pinned top-leading (stats HUD owns
    /// top-trailing). A plain drag then rotates / zooms / pans accordingly.
    private var cameraModeControl: some View {
        Picker("Camera mode", selection: $cameraMode) {
            ForEach(CameraInteractionMode.allCases) { mode in
                Image(systemName: mode.symbol)
                    .help(mode.helpText)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - NSViewRepresentable

struct ViewportRepresentable: NSViewRepresentable {

    let modelURL: URL?
    let mode: CameraInteractionMode
    let editedMesh: EditedMeshData?
    let onPickFace: ((Int, Bool) -> Void)?
    let hoverPreview: Bool
    let onHoverFace: ((Int?) -> Void)?
    @Binding var stats: SceneStats?
    @Binding var loadError: String?

    func makeCoordinator() -> ViewportCoordinator { ViewportCoordinator() }

    func makeNSView(context: Context) -> InteractiveARView {
        let view = InteractiveARView(frame: .zero)
        context.coordinator.attach(to: view)
        context.coordinator.onStats = { stats = $0 }
        context.coordinator.onError = { loadError = $0 }
        view.interactionMode = mode
        return view
    }

    func updateNSView(_ view: InteractiveARView, context: Context) {
        context.coordinator.onStats = { stats = $0 }
        context.coordinator.onError = { loadError = $0 }
        view.interactionMode = mode
        context.coordinator.load(url: modelURL)
        context.coordinator.applyEditedMesh(editedMesh, onPickFace: onPickFace,
                                            hoverPreview: hoverPreview, onHoverFace: onHoverFace)
    }
}

// MARK: - Coordinator

@MainActor
final class ViewportCoordinator {

    private weak var view: InteractiveARView?
    private let cameraAnchor = AnchorEntity(world: .zero)
    private let cameraEntity = PerspectiveCamera()
    private let modelAnchor = AnchorEntity(world: .zero)
    private let gridAnchor = AnchorEntity(world: .zero)

    private var camera = OrbitCamera()
    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?
    private var modelBounds: (center: SIMD3<Float>, radius: Float)?

    var onStats: ((SceneStats?) -> Void)?
    var onError: ((String?) -> Void)?

    func attach(to view: InteractiveARView) {
        self.view = view
        view.environment.background = .color(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1))
        cameraEntity.camera.fieldOfViewInDegrees = Float(OrbitCamera.verticalFOV * 180 / .pi)
        cameraAnchor.addChild(cameraEntity)
        view.scene.addAnchor(cameraAnchor)
        view.scene.addAnchor(modelAnchor)
        view.scene.addAnchor(gridAnchor)
        rebuildGrid(halfExtent: 1)
        applyCamera()

        view.onOrbit = { [weak self] dx, dy in
            self?.camera.orbit(deltaAzimuth: -dx * 0.01, deltaElevation: dy * 0.01)
            self?.applyCamera()
        }
        view.onPan = { [weak self] dx, dy in
            guard let self, let height = self.view?.bounds.height, height > 0 else { return }
            self.camera.panByScreenDelta(deltaX: dx, deltaY: -dy, viewportHeight: Double(height))
            self.applyCamera()
        }
        view.onDolly = { [weak self] amount in
            self?.camera.dolly(amount)
            self?.applyCamera()
        }
        view.onFrame = { [weak self] in self?.frameModel() }
    }

    func load(url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        loadTask?.cancel()
        modelAnchor.children.removeAll()
        onStats?(nil)
        onError?(nil)
        guard let url else { return }

        loadTask = Task { @MainActor [weak self] in
            do {
                // Fast path: Apple's loader for best material/skinning fidelity.
                let entity = try Self.loadEntity(url)
                guard let self, !Task.isCancelled, self.loadedURL == url else { return }
                self.modelAnchor.addChild(entity)
                let bounds = entity.visualBounds(relativeTo: nil)
                self.modelBounds = (bounds.center, max(bounds.boundingRadius, 1e-4))
                self.rebuildGrid(halfExtent: GridModel.fittingHalfExtent(forModelRadius: bounds.boundingRadius))
                self.frameModel()
                self.onStats?(Self.collectStats(from: entity, boundsSize: bounds.extents))
            } catch {
                guard !Task.isCancelled else { return }
                self?.onError?("Viewport could not load model: \(error.localizedDescription)")
            }
        }
    }

    /// macOS 14-compatible load (the async `Entity(contentsOf:)` is 15+).
    /// Sync wrapper keeps the call legal from the async task; acceptable for
    /// Phase 1 typical asset sizes, revisit with off-main streaming later.
    private static func loadEntity(_ url: URL) throws -> Entity {
        try Entity.load(contentsOf: url)
    }

    // MARK: Component-edit rendering + picking (Phase 6)

    private let editAnchor = AnchorEntity(world: .zero)
    private var editData: EditedMeshData?
    private var hiddenOriginal: Entity?
    private var onPickFace: ((Int, Bool) -> Void)?
    private var onHoverFace: ((Int?) -> Void)?
    private var hoverEntity: ModelEntity?
    private var hoveredFace: Int?
    /// BVH rebuilt per mesh revision; traversed per hover/click event.
    private var pickAccelerator: PickAccelerator?

    /// Swap the file-loaded entity for the live edited mesh (flat-shaded, with
    /// an amber overlay on the selected faces); restore it when editing ends.
    func applyEditedMesh(_ data: EditedMeshData?, onPickFace: ((Int, Bool) -> Void)?,
                         hoverPreview: Bool = false, onHoverFace: ((Int?) -> Void)? = nil) {
        self.onPickFace = onPickFace
        self.onHoverFace = onHoverFace
        view?.onEditClick = data == nil
            ? nil : { [weak self] point, additive in self?.pick(at: point, additive: additive) }
        view?.onHoverMove = (data == nil || !hoverPreview)
            ? nil : { [weak self] point in self?.hover(at: point) }
        if data == nil || !hoverPreview { setHoveredFace(nil) }
        guard data != editData else { return }
        editData = data
        pickAccelerator = data.map(PickAccelerator.init)
        setHoveredFace(nil) // geometry changed; stale hover would mislead
        editAnchor.children.removeAll()
        hoverEntity = nil

        guard let data else {
            hiddenOriginal?.isEnabled = true
            hiddenOriginal = nil
            if editAnchor.parent != nil { editAnchor.removeFromParent() }
            return
        }
        if editAnchor.parent == nil { view?.scene.addAnchor(editAnchor) }

        // Hide the file-loaded entity for this prim; the edit mesh replaces it.
        if hiddenOriginal == nil,
           let original = modelAnchor.findEntity(primPath: data.primPath)
               ?? modelAnchor.findEntity(named: data.primName) {
            original.isEnabled = false
            hiddenOriginal = original
        }
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4

        if let mesh = Self.meshResource(MeshFlattener.flatten(data)) {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: NSColor(srgbRed: 0.62, green: 0.65, blue: 0.7, alpha: 1))
            material.roughness = 0.6
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.transform = Transform(matrix: worldMatrix)
            editAnchor.addChild(entity)
        }
        if !data.selectedFaces.isEmpty,
           let highlight = Self.meshResource(
            MeshFlattener.flatten(data, faces: data.selectedFaces.sorted()), inflate: 0.003) {
            let entity = ModelEntity(
                mesh: highlight,
                materials: [UnlitMaterial(color: NSColor(srgbRed: 0.91, green: 0.7, blue: 0.25, alpha: 0.55))])
            entity.transform = Transform(matrix: worldMatrix)
            editAnchor.addChild(entity)
        }
    }

    /// Triangle buffers → MeshResource, optionally puffed along the normals so
    /// the selection overlay never z-fights the base mesh.
    private static func meshResource(_ buffers: MeshFlattener.Buffers, inflate: Float = 0) -> MeshResource? {
        guard !buffers.triangleIndices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "editedMesh")
        let positions = inflate == 0 ? buffers.positions
            : zip(buffers.positions, buffers.normals).map { $0 + $1 * inflate }
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(buffers.normals)
        descriptor.primitives = .triangles(buffers.triangleIndices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Click → world ray (shared orbit-camera math) → prim-local ray → face.
    /// `additive` (⇧-click) toggles the face against the current selection.
    private func pick(at point: CGPoint, additive: Bool) {
        guard let onPickFace, let hit = faceHit(at: point) else { return }
        onPickFace(hit, additive)
    }

    /// Cursor move → the face an op would target, previewed live.
    private func hover(at point: CGPoint) {
        setHoveredFace(faceHit(at: point))
    }

    private func faceHit(at point: CGPoint) -> Int? {
        guard let data = editData, let view,
              var ray = CameraRay.make(camera: camera, viewSize: view.bounds.size, point: point)
        else { return nil }
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4
        let inverse = worldMatrix.inverse
        let origin4 = inverse * SIMD4<Float>(SIMD3<Float>(ray.origin), 1)
        let dir4 = inverse * SIMD4<Float>(SIMD3<Float>(ray.direction), 0)
        ray = CameraRay.Ray(origin: SIMD3<Double>(SIMD3(origin4.x, origin4.y, origin4.z)),
                            direction: SIMD3<Double>(SIMD3(dir4.x, dir4.y, dir4.z)))
        return (pickAccelerator?.pickFace(ray: ray) ?? MeshPicker.pickFace(ray: ray, in: data))?.faceIndex
    }

    /// Rebuilds the hover highlight (accent blue, distinct from the amber
    /// selection) and reports the change up for the HUD readout.
    private func setHoveredFace(_ face: Int?) {
        guard face != hoveredFace else { return }
        hoveredFace = face
        onHoverFace?(face)
        hoverEntity?.removeFromParent()
        hoverEntity = nil
        guard let face, let data = editData,
              let mesh = Self.meshResource(MeshFlattener.flatten(data, faces: [face]), inflate: 0.005)
        else { return }
        let entity = ModelEntity(
            mesh: mesh,
            materials: [UnlitMaterial(color: NSColor(srgbRed: 0.36, green: 0.62, blue: 1, alpha: 0.4))])
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4
        entity.transform = Transform(matrix: worldMatrix)
        editAnchor.addChild(entity)
        hoverEntity = entity
    }

    private func frameModel() {
        guard let modelBounds else { return }
        camera.frame(
            center: SIMD3<Double>(modelBounds.center),
            radius: Double(modelBounds.radius))
        applyCamera()
    }

    private func applyCamera() {
        cameraEntity.transform = Transform(matrix: float4x4(lookAtFrom: SIMD3<Float>(camera.position),
                                                            target: SIMD3<Float>(camera.target)))
    }

    private func rebuildGrid(halfExtent: Float) {
        gridAnchor.children.removeAll()
        let lineMaterial = UnlitMaterial(color: NSColor(white: 1, alpha: 0.12))
        let axisMaterial = UnlitMaterial(color: NSColor(white: 1, alpha: 0.35))
        let thickness = halfExtent / 900
        for segment in GridModel.segments(halfExtent: halfExtent, divisions: 10) {
            let alongX = segment.start.z == segment.end.z
            let size = SIMD3<Float>(
                alongX ? segment.length : thickness,
                thickness,
                alongX ? thickness : segment.length)
            let entity = ModelEntity(
                mesh: .generateBox(size: size),
                materials: [segment.isAxis ? axisMaterial : lineMaterial])
            entity.position = segment.midpoint
            gridAnchor.addChild(entity)
        }
    }

    static func collectStats(from entity: Entity, boundsSize: SIMD3<Float>) -> SceneStats {
        var stats = SceneStats(boundsSize: boundsSize)
        var materialCount = 0
        entity.visit { child in
            guard let model = (child as? (any HasModel))?.model else { return }
            stats.meshes += 1
            materialCount += model.materials.count
            for part in model.mesh.contents.models.flatMap(\.parts) {
                stats.vertices += part.positions.count
                stats.triangles += (part.triangleIndices?.count ?? 0) / 3
            }
        }
        stats.materials = materialCount
        return stats
    }
}

extension Entity {
    /// Finds the descendant whose named-ancestor chain matches the prim path
    /// ("/Rig/Panel" → an entity named "Panel" under one named "Rig"),
    /// ignoring RealityKit's unnamed wrapper entities. `nil` for empty paths
    /// or no match — callers then fall back to plain name lookup.
    func findEntity(primPath: String) -> Entity? {
        let components = primPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var match: Entity?
        visit { entity in
            guard match == nil, entity.name == components.last else { return }
            // Walk up collecting named ancestors; must end with the path.
            var names: [String] = []
            var cursor: Entity? = entity
            while let current = cursor {
                if !current.name.isEmpty { names.append(current.name) }
                cursor = current.parent
            }
            if Array(names.prefix(components.count)) == components.reversed().map({ $0 }) {
                match = entity
            }
        }
        return match
    }

    func visit(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.visit(body) }
    }
}

extension float4x4 {
    /// Right-handed look-at (camera looks down -Z), Y-up.
    init(lookAtFrom position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0]) {
        let zAxis = simd_normalize(position - target)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        self.init(columns: (
            SIMD4(xAxis, 0),
            SIMD4(yAxis, 0),
            SIMD4(zAxis, 0),
            SIMD4(position, 1)))
    }
}

// MARK: - Input

/// ARView subclass translating AppKit input into camera gestures:
/// drag = orbit, ⇧-drag = pan, scroll/pinch = dolly, F = frame (specs/viewport.md).
final class InteractiveARView: ARView {

    var onOrbit: ((Double, Double) -> Void)?
    var onPan: ((Double, Double) -> Void)?
    var onDolly: ((Double) -> Void)?
    var onFrame: (() -> Void)?
    /// Component picking in edit mode: fires with the click point in top-left
    /// view coordinates when a press releases without dragging. The Bool is
    /// `true` when ⇧ was held (additive multi-select).
    var onEditClick: ((CGPoint, Bool) -> Void)?
    /// Live hover preview in edit mode: fires with the cursor point (top-left
    /// coordinates) on every move, and `nil`-equivalent via mouseExited.
    var onHoverMove: ((CGPoint) -> Void)? {
        didSet { updateTrackingAreas() }
    }

    private var mouseDownPoint: CGPoint?
    private var dragged = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard onHoverMove != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let onHoverMove else { return }
        let p = convert(event.locationInWindow, from: nil)
        onHoverMove(CGPoint(x: p.x, y: bounds.height - p.y))
    }

    override func mouseExited(with event: NSEvent) {
        // Off-view: park the hover point outside any geometry so the
        // coordinator clears the highlight.
        onHoverMove?(CGPoint(x: -1e6, y: -1e6))
    }

    /// Camera action a plain drag performs; driven by the top-leading buttons.
    var interactionMode: CameraInteractionMode = .rotate

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged, let onEditClick, let down = mouseDownPoint else { return }
        let up = convert(event.locationInWindow, from: nil)
        guard abs(up.x - down.x) < 3, abs(up.y - down.y) < 3 else { return }
        // AppKit's origin is bottom-left; picking math wants top-left.
        onEditClick(CGPoint(x: up.x, y: bounds.height - up.y),
                    event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let dx = Double(event.deltaX), dy = Double(event.deltaY)
        // ⇧-drag always pans (power-user shortcut, independent of mode).
        guard !event.modifierFlags.contains(.shift) else {
            onPan?(dx, dy)
            return
        }
        switch interactionMode {
        case .rotate: onOrbit?(dx, dy)
        case .pan: onPan?(dx, dy)
        case .zoom: onDolly?(-dy * 0.01)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        onPan?(Double(event.deltaX), Double(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        onDolly?(Double(-event.scrollingDeltaY) * 0.02)
    }

    override func magnify(with event: NSEvent) {
        onDolly?(Double(-event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": onFrame?()
        default: super.keyDown(with: event)
        }
    }
}
#endif
