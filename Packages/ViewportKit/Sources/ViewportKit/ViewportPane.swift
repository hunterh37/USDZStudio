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

/// A programmatic camera pose (guided tour / scripted flythroughs). While
/// non-nil it overrides the user-driven orbit camera each frame; pass `nil`
/// to hand control back to mouse gestures.
public struct ViewportCameraPose: Equatable, Sendable {
    public var target: SIMD3<Double>
    public var distance: Double
    public var azimuth: Double
    public var elevation: Double

    public init(target: SIMD3<Double> = .zero, distance: Double = 2,
                azimuth: Double = 0, elevation: Double = 0.3) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
    }
}

public struct ViewportPane: View {

    let modelURL: URL?
    /// Absolute path strings of every prim currently on the live stage, plus a
    /// revision that bumps on each document mutation. The viewport prunes
    /// file-loaded entities whose prim was deleted (and restores them on undo)
    /// so structural edits show up without a full reload. `nil` = no live
    /// stage; render the file as-is.
    let livePrimPaths: Set<String>?
    let sceneRevision: Int
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
    /// Scripted camera (guided tour): while non-nil the pose overrides the
    /// user-driven orbit camera. `nil` = normal mouse control.
    let cameraPose: ViewportCameraPose?
    /// Live per-prim local transforms (column-major, RealityKit convention)
    /// keyed by absolute prim path — applied onto the file-loaded entities so
    /// scripted/tweened transform edits are visible without a reload.
    let liveTransforms: [String: float4x4]?
    /// Live material overrides keyed by absolute (mesh) prim path — applied onto
    /// the file-loaded entities so recolour/roughness/etc. edits are visible
    /// without a reload. `nil` = leave the file's baked materials as-is.
    let materialOverrides: [String: MaterialOverride]?
    @State private var stats: SceneStats?
    @State private var showStats = true
    @State private var loadError: String?
    @State private var cameraMode: CameraInteractionMode = .rotate
    @StateObject private var cameraLink = ViewportCameraLink()

    public init(modelURL: URL?,
                livePrimPaths: Set<String>? = nil,
                sceneRevision: Int = 0,
                editedMesh: EditedMeshData? = nil,
                onPickFace: ((Int, Bool) -> Void)? = nil,
                hoverPreview: Bool = false,
                onHoverFace: ((Int?) -> Void)? = nil,
                cameraPose: ViewportCameraPose? = nil,
                liveTransforms: [String: float4x4]? = nil,
                materialOverrides: [String: MaterialOverride]? = nil) {
        self.modelURL = modelURL
        self.livePrimPaths = livePrimPaths
        self.sceneRevision = sceneRevision
        self.editedMesh = editedMesh
        self.onPickFace = onPickFace
        self.hoverPreview = hoverPreview
        self.onHoverFace = onHoverFace
        self.cameraPose = cameraPose
        self.liveTransforms = liveTransforms
        self.materialOverrides = materialOverrides
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewportRepresentable(modelURL: modelURL, mode: cameraMode,
                                  livePrimPaths: livePrimPaths, sceneRevision: sceneRevision,
                                  editedMesh: editedMesh, onPickFace: onPickFace,
                                  hoverPreview: hoverPreview, onHoverFace: onHoverFace,
                                  cameraLink: cameraLink,
                                  cameraPose: cameraPose, liveTransforms: liveTransforms,
                                  materialOverrides: materialOverrides,
                                  stats: $stats, loadError: $loadError)
            cameraModeControl
            AxisGizmoView(link: cameraLink)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)
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
    let livePrimPaths: Set<String>?
    let sceneRevision: Int
    let editedMesh: EditedMeshData?
    let onPickFace: ((Int, Bool) -> Void)?
    let hoverPreview: Bool
    let onHoverFace: ((Int?) -> Void)?
    let cameraLink: ViewportCameraLink
    let cameraPose: ViewportCameraPose?
    let liveTransforms: [String: float4x4]?
    let materialOverrides: [String: MaterialOverride]?
    @Binding var stats: SceneStats?
    @Binding var loadError: String?

    func makeCoordinator() -> ViewportCoordinator { ViewportCoordinator() }

    func makeNSView(context: Context) -> InteractiveARView {
        let view = InteractiveARView(frame: .zero)
        context.coordinator.attach(to: view, cameraLink: cameraLink)
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
        if let livePrimPaths {
            context.coordinator.applyLivePrimPaths(livePrimPaths, revision: sceneRevision)
        }
        context.coordinator.applyEditedMesh(editedMesh, onPickFace: onPickFace,
                                            hoverPreview: hoverPreview, onHoverFace: onHoverFace)
        context.coordinator.applyCameraPose(cameraPose)
        context.coordinator.applyLiveTransforms(liveTransforms)
        context.coordinator.applyMaterialOverrides(materialOverrides)
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
    private weak var cameraLink: ViewportCameraLink?

    func attach(to view: InteractiveARView, cameraLink: ViewportCameraLink? = nil) {
        self.view = view
        self.cameraLink = cameraLink
        cameraLink?.snapHandler = { [weak self] axis in
            guard let self else { return }
            let preset = AxisGizmoModel.preset(for: axis, currentAzimuth: self.camera.azimuth)
            self.camera.azimuth = preset.azimuth
            self.camera.elevation = preset.elevation
            self.applyCamera()
        }
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
        baselinePrimPaths = nil
        appliedSceneRevision = nil
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
                // Edits may have landed while the file was loading; bring the
                // freshly loaded entities in line with the live stage.
                self.pruneModelEntities()
                self.reapplyLiveTransforms()
                self.reapplyMaterialOverrides()
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

    // MARK: Scripted camera + live transforms (guided tour / scripted edits)

    private var appliedPose: ViewportCameraPose?
    private var appliedTransforms: [String: float4x4]?

    /// While a pose is supplied it drives the camera absolutely (the guided
    /// tour's slow orbit). User gestures keep mutating `camera`, but each new
    /// pose reasserts the scripted view; a `nil` pose returns control.
    func applyCameraPose(_ pose: ViewportCameraPose?) {
        guard pose != appliedPose else { return }
        appliedPose = pose
        guard let pose else { return }
        camera.target = pose.target
        camera.distance = OrbitCamera.clampDistance(pose.distance)
        camera.azimuth = OrbitCamera.wrapAzimuth(pose.azimuth)
        camera.elevation = OrbitCamera.clampElevation(pose.elevation)
        applyCamera()
    }

    /// Applies per-prim local transforms onto the matching file-loaded
    /// entities so scripted transform tweens render live. Re-applied after an
    /// async model load so early frames aren't lost.
    func applyLiveTransforms(_ transforms: [String: float4x4]?) {
        guard transforms != appliedTransforms else { return }
        appliedTransforms = transforms
        reapplyLiveTransforms()
    }

    private func reapplyLiveTransforms() {
        guard let transforms = appliedTransforms else { return }
        for (path, matrix) in transforms {
            guard let entity = modelAnchor.findEntity(primPath: path) else { continue }
            entity.transform = Transform(matrix: matrix)
        }
    }

    // MARK: Live material overrides (recolour / surface-input edits)

    private var appliedMaterialOverrides: [String: MaterialOverride]?

    /// Applies resolved material values onto the matching file-loaded entities
    /// so recolour and other surface-input edits render live. Re-applied after
    /// an async model load so edits made while loading aren't lost.
    ///
    /// Each edited material's slot is replaced with a `PhysicallyBasedMaterial`
    /// built from its UsdPreviewSurface inputs. Untouched materials keep the
    /// loader's original (higher-fidelity, texture-preserving) material — the
    /// document only emits an override for a material whose inputs it actually
    /// authored, so this never flattens a material the user didn't edit.
    func applyMaterialOverrides(_ overrides: [String: MaterialOverride]?) {
        guard overrides != appliedMaterialOverrides else { return }
        appliedMaterialOverrides = overrides
        reapplyMaterialOverrides()
    }

    private func reapplyMaterialOverrides() {
        guard let overrides = appliedMaterialOverrides else { return }
        for (path, override) in overrides {
            guard let entity = modelAnchor.findEntity(primPath: path) else { continue }
            applyOverride(override, toSubtreeOf: entity)
        }
    }

    /// Sets the material on `entity` and any *unnamed* wrapper descendants the
    /// loader inserted between the prim's entity and its `ModelComponent` — but
    /// stops at named children, which are other prims with their own overrides.
    private func applyOverride(_ override: MaterialOverride, toSubtreeOf entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            let material = Self.physicallyBasedMaterial(override)
            model.materials = Array(repeating: material, count: max(1, model.materials.count))
            entity.components.set(model)
        }
        for child in entity.children where child.name.isEmpty {
            applyOverride(override, toSubtreeOf: child)
        }
    }

    /// A `PhysicallyBasedMaterial` from resolved surface values. Colours arrive
    /// sRGB (converted by the document), ready for `NSColor(srgbRed:…)`.
    static func physicallyBasedMaterial(_ o: MaterialOverride) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: nsColor(o.baseColor, alpha: o.opacity))
        material.roughness = .init(floatLiteral: o.roughness)
        material.metallic = .init(floatLiteral: o.metallic)
        if o.emissiveColor != .zero {
            material.emissiveColor = .init(color: nsColor(o.emissiveColor))
            material.emissiveIntensity = 1
        }
        if o.opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: o.opacity))
        }
        return material
    }

    private static func nsColor(_ c: SIMD3<Float>, alpha: Float = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(alpha))
    }

    // MARK: Live-stage sync (structural edits)

    /// Prim paths present on the live stage right now.
    private var livePrimPaths: Set<String>?
    /// Prim paths present when this file's first live set arrived — the set the
    /// file-loaded entity tree corresponds to. Entities whose baseline prim
    /// disappears from the live set get disabled; undo re-enables them.
    private var baselinePrimPaths: Set<String>?
    private var appliedSceneRevision: Int?

    /// Syncs the file-loaded entities against the live stage's prim set.
    /// Cheap when nothing changed (revision-gated); otherwise one walk of the
    /// entity tree.
    func applyLivePrimPaths(_ paths: Set<String>, revision: Int) {
        guard revision != appliedSceneRevision else { return }
        appliedSceneRevision = revision
        livePrimPaths = paths
        if baselinePrimPaths == nil { baselinePrimPaths = paths }
        pruneModelEntities()
    }

    private func pruneModelEntities() {
        guard let live = livePrimPaths, let baseline = baselinePrimPaths else { return }
        for child in modelAnchor.children {
            prune(child, parentPath: "", live: live, baseline: baseline)
        }
    }

    /// Walks the entity tree, mapping entities to prim paths by name. Loader
    /// wrapper nodes (unnamed, or names that never were prims) are transparent:
    /// their children are matched against the same parent path.
    private func prune(_ entity: Entity, parentPath: String, live: Set<String>, baseline: Set<String>) {
        // A mesh-edit session manages this entity's enablement itself.
        guard entity !== hiddenOriginal else { return }
        let name = entity.name
        if !name.isEmpty {
            let path = parentPath + "/" + name
            if baseline.contains(path) {
                let present = live.contains(path)
                if entity.isEnabled != present { entity.isEnabled = present }
                guard present else { return } // whole subtree is gone with it
                for child in entity.children {
                    prune(child, parentPath: path, live: live, baseline: baseline)
                }
                return
            }
        }
        for child in entity.children {
            prune(child, parentPath: parentPath, live: live, baseline: baseline)
        }
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
            // Use the prim's edited material if one is overridden, so the mesh
            // being edited keeps its real colour rather than a flat grey.
            let material: PhysicallyBasedMaterial
            if let override = appliedMaterialOverrides?[data.primPath] {
                material = Self.physicallyBasedMaterial(override)
            } else {
                material = {
                    var m = PhysicallyBasedMaterial()
                    m.baseColor = .init(tint: NSColor(srgbRed: 0.62, green: 0.65, blue: 0.7, alpha: 1))
                    m.roughness = 0.6
                    return m
                }()
            }
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
        // A scripted pose owns the camera; auto-framing would fight it.
        guard appliedPose == nil, let modelBounds else { return }
        camera.frame(
            center: SIMD3<Double>(modelBounds.center),
            radius: Double(modelBounds.radius))
        applyCamera()
    }

    private func applyCamera() {
        cameraEntity.transform = Transform(matrix: float4x4(lookAtFrom: SIMD3<Float>(camera.position),
                                                            target: SIMD3<Float>(camera.target)))
        cameraLink?.publish(camera)
    }

    private func rebuildGrid(halfExtent: Float) {
        gridAnchor.children.removeAll()
        let lineMaterial = UnlitMaterial(color: NSColor(white: 1, alpha: 0.12))
        // DCC-standard axis tints (matching the orientation gizmo): X red, Z blue.
        let xAxisMaterial = UnlitMaterial(
            color: NSColor(srgbRed: 0.91, green: 0.34, blue: 0.30, alpha: 0.6))
        let zAxisMaterial = UnlitMaterial(
            color: NSColor(srgbRed: 0.34, green: 0.55, blue: 0.98, alpha: 0.6))
        let thickness = halfExtent / 900
        for segment in GridModel.segments(halfExtent: halfExtent, divisions: 10) {
            let alongX = segment.start.z == segment.end.z
            let size = SIMD3<Float>(
                alongX ? segment.length : thickness,
                thickness,
                alongX ? thickness : segment.length)
            let material: UnlitMaterial = switch segment.axis {
            case .x: xAxisMaterial
            case .z: zAxisMaterial
            case nil: lineMaterial
            }
            let entity = ModelEntity(
                mesh: .generateBox(size: size),
                materials: [material])
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
