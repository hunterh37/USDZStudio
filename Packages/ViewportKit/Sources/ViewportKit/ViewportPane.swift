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
    /// The document's live scene description; prims absent from the loaded file
    /// are synthesized from it (specs/viewport.md "Rendering").
    let scene: ViewportScene?
    /// Live component-edit geometry replacing the file-loaded model for one
    /// prim (Phase 6). `nil` = plain file rendering.
    let editedMesh: EditedMeshData?
    /// Called with the picked face index (authored order) on a click while
    /// `editedMesh` is active. The second parameter is `true` when ⇧ was held
    /// (additive selection: toggle the face into/out of the current set).
    let onPickFace: ((Int, Bool) -> Void)?
    /// Blender-style Tab toggle: fires when Tab is pressed while the viewport
    /// has keyboard focus. Wired by the host to `document.toggleMeshEditMode()`.
    let onToggleEditMode: (() -> Void)?
    /// Live hover preview: highlight the face under the cursor (the one a
    /// click / op would target). Reported up so the HUD can name it.
    let hoverPreview: Bool
    let onHoverFace: ((Int?) -> Void)?
    /// Extrude handle next to the selected face(s) in mesh edit mode; `nil`
    /// hides it. Dragging the handle reports phases through `onGizmoDrag`.
    let extrudeGizmo: ExtrudeGizmoDescriptor?
    let onGizmoDrag: ((ExtrudeGizmoDragPhase) -> Void)?
    /// Object-mode move gizmo (three XYZ arrows at the selection's world
    /// pivot); `nil` hides it. Dragging an arrow reports phases through
    /// `onTranslateGizmoDrag`.
    let translateGizmo: TranslateGizmoDescriptor?
    let onTranslateGizmoDrag: ((TranslateGizmoDragPhase) -> Void)?
    /// Object-mode rotate gizmo (three axis rings at the selection's world
    /// pivot); `nil` hides it. Dragging a ring reports phases through
    /// `onRotateGizmoDrag`.
    let rotateGizmo: RotateGizmoDescriptor?
    let onRotateGizmoDrag: ((RotateGizmoDragPhase) -> Void)?
    /// Object-mode scale gizmo (per-axis box handles + uniform centre at the
    /// selection's world pivot); `nil` hides it. Dragging a handle reports
    /// phases through `onScaleGizmoDrag`.
    let scaleGizmo: ScaleGizmoDescriptor?
    let onScaleGizmoDrag: ((ScaleGizmoDragPhase) -> Void)?
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
    /// Image-based lighting + background state (specs/viewport.md "Environment
    /// & Lighting"). The pure model lives in ``EnvironmentSettings``; this layer
    /// only installs the resolved source, exposure, and background.
    let environment: EnvironmentSettings
    /// Animation playhead in **seconds from the clip start** (specs/viewport.md
    /// §Animation Playback). Non-nil while the transport bar drives playback: the
    /// viewport seeks the loaded entity's `AnimationResource` to this time and
    /// pauses it there, so scrub/play/loop all reduce to "show the pose at time
    /// T". `nil` leaves the model at its default (rest) pose. The transport does
    /// the time-code→seconds conversion (honouring `timeCodesPerSecond`).
    let animationTime: Double?
    @State private var stats: SceneStats?
    @State private var showStats = true
    @State private var loadError: String?
    @State private var cameraMode: CameraInteractionMode = .rotate
    @State private var debugMode: DebugViewMode = .shaded
    @StateObject private var cameraLink = ViewportCameraLink()

    public init(modelURL: URL?,
                livePrimPaths: Set<String>? = nil,
                sceneRevision: Int = 0,
                scene: ViewportScene? = nil,
                editedMesh: EditedMeshData? = nil,
                onPickFace: ((Int, Bool) -> Void)? = nil,
                onToggleEditMode: (() -> Void)? = nil,
                hoverPreview: Bool = false,
                onHoverFace: ((Int?) -> Void)? = nil,
                extrudeGizmo: ExtrudeGizmoDescriptor? = nil,
                onGizmoDrag: ((ExtrudeGizmoDragPhase) -> Void)? = nil,
                translateGizmo: TranslateGizmoDescriptor? = nil,
                onTranslateGizmoDrag: ((TranslateGizmoDragPhase) -> Void)? = nil,
                rotateGizmo: RotateGizmoDescriptor? = nil,
                onRotateGizmoDrag: ((RotateGizmoDragPhase) -> Void)? = nil,
                scaleGizmo: ScaleGizmoDescriptor? = nil,
                onScaleGizmoDrag: ((ScaleGizmoDragPhase) -> Void)? = nil,
                cameraPose: ViewportCameraPose? = nil,
                liveTransforms: [String: float4x4]? = nil,
                materialOverrides: [String: MaterialOverride]? = nil,
                environment: EnvironmentSettings = EnvironmentSettings(),
                animationTime: Double? = nil) {
        self.modelURL = modelURL
        self.livePrimPaths = livePrimPaths
        self.sceneRevision = sceneRevision
        self.scene = scene
        self.editedMesh = editedMesh
        self.onPickFace = onPickFace
        self.onToggleEditMode = onToggleEditMode
        self.hoverPreview = hoverPreview
        self.onHoverFace = onHoverFace
        self.extrudeGizmo = extrudeGizmo
        self.onGizmoDrag = onGizmoDrag
        self.translateGizmo = translateGizmo
        self.onTranslateGizmoDrag = onTranslateGizmoDrag
        self.rotateGizmo = rotateGizmo
        self.onRotateGizmoDrag = onRotateGizmoDrag
        self.scaleGizmo = scaleGizmo
        self.onScaleGizmoDrag = onScaleGizmoDrag
        self.cameraPose = cameraPose
        self.liveTransforms = liveTransforms
        self.materialOverrides = materialOverrides
        self.environment = environment
        self.animationTime = animationTime
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewportRepresentable(modelURL: modelURL, mode: cameraMode,
                                  livePrimPaths: livePrimPaths, sceneRevision: sceneRevision,
                                  scene: scene,
                                  editedMesh: editedMesh, onPickFace: onPickFace,
                                  onToggleEditMode: onToggleEditMode,
                                  hoverPreview: hoverPreview, onHoverFace: onHoverFace,
                                  extrudeGizmo: extrudeGizmo, onGizmoDrag: onGizmoDrag,
                                  translateGizmo: translateGizmo,
                                  onTranslateGizmoDrag: onTranslateGizmoDrag,
                                  rotateGizmo: rotateGizmo,
                                  onRotateGizmoDrag: onRotateGizmoDrag,
                                  scaleGizmo: scaleGizmo,
                                  onScaleGizmoDrag: onScaleGizmoDrag,
                                  cameraLink: cameraLink,
                                  cameraPose: cameraPose, liveTransforms: liveTransforms,
                                  materialOverrides: materialOverrides,
                                  environment: environment,
                                  animationTime: animationTime,
                                  debugMode: debugMode,
                                  stats: $stats, loadError: $loadError)
            VStack(alignment: .leading, spacing: 6) {
                cameraModeControl
                debugModeControl
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    /// Debug view-mode segmented control (specs/viewport.md "Debug View
    /// Modes"): shaded / wireframe / normals / UV checker / matcap. Swaps the
    /// projection materials (or adds the wireframe overlay) live.
    private var debugModeControl: some View {
        Picker("Debug view mode", selection: $debugMode) {
            ForEach(DebugViewMode.allCases) { mode in
                Image(systemName: mode.symbol)
                    .help(mode.helpText)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - NSViewRepresentable

struct ViewportRepresentable: NSViewRepresentable {

    let modelURL: URL?
    let mode: CameraInteractionMode
    let livePrimPaths: Set<String>?
    let sceneRevision: Int
    let scene: ViewportScene?
    let editedMesh: EditedMeshData?
    let onPickFace: ((Int, Bool) -> Void)?
    let onToggleEditMode: (() -> Void)?
    let hoverPreview: Bool
    let onHoverFace: ((Int?) -> Void)?
    let extrudeGizmo: ExtrudeGizmoDescriptor?
    let onGizmoDrag: ((ExtrudeGizmoDragPhase) -> Void)?
    let translateGizmo: TranslateGizmoDescriptor?
    let onTranslateGizmoDrag: ((TranslateGizmoDragPhase) -> Void)?
    let rotateGizmo: RotateGizmoDescriptor?
    let onRotateGizmoDrag: ((RotateGizmoDragPhase) -> Void)?
    let scaleGizmo: ScaleGizmoDescriptor?
    let onScaleGizmoDrag: ((ScaleGizmoDragPhase) -> Void)?
    let cameraLink: ViewportCameraLink
    let cameraPose: ViewportCameraPose?
    let liveTransforms: [String: float4x4]?
    let materialOverrides: [String: MaterialOverride]?
    let environment: EnvironmentSettings
    let animationTime: Double?
    let debugMode: DebugViewMode
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
        // Bare-Tab hotkey lives on the first responder (the viewport view), not
        // the SwiftUI key-equivalent fallback which AppKit's key-view loop
        // pre-empts. Re-set each update so it tracks the current host closure.
        view.onToggleEditMode = onToggleEditMode
        context.coordinator.load(url: modelURL)
        context.coordinator.applyScene(scene)
        if let livePrimPaths {
            context.coordinator.applyLivePrimPaths(livePrimPaths, revision: sceneRevision)
        }
        context.coordinator.applyEditedMesh(editedMesh, onPickFace: onPickFace,
                                            hoverPreview: hoverPreview, onHoverFace: onHoverFace)
        context.coordinator.applyExtrudeGizmo(extrudeGizmo, onDrag: onGizmoDrag)
        context.coordinator.applyTranslateGizmo(translateGizmo, onDrag: onTranslateGizmoDrag)
        context.coordinator.applyRotateGizmo(rotateGizmo, onDrag: onRotateGizmoDrag)
        context.coordinator.applyScaleGizmo(scaleGizmo, onDrag: onScaleGizmoDrag)
        context.coordinator.applyCameraPose(cameraPose)
        context.coordinator.applyLiveTransforms(liveTransforms)
        context.coordinator.applyMaterialOverrides(materialOverrides)
        context.coordinator.applyEnvironment(environment)
        context.coordinator.applyAnimationTime(animationTime)
        context.coordinator.applyDebugMode(debugMode)
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
    /// Root of the *loader-produced* entity tree, kept distinct from
    /// `modelAnchor` so provenance stays unambiguous: anything reachable from
    /// here came from the file, anything else the applier synthesized. Feeding
    /// the applier a lookup rooted at `modelAnchor` instead would let it find
    /// its own entities and skip every insert.
    private var loadedRoot: Entity?
    /// Applies snapshot-driven scene diffs (prims the file never contained).
    private lazy var sceneApplier = SceneGraphApplier(
        root: modelAnchor,
        findLoaded: { [weak self] path in self?.loadedRoot?.findEntity(primPath: path) })
    /// Most recent scene from the document, replayed after an async load lands.
    private var latestScene: ViewportScene?
    /// Whether a file load is in flight — scene diffs wait for it so the seed
    /// baseline is computed against the finished entity tree.
    private var isLoading = false
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
        // One dispatcher owns the gizmo capture callbacks; whichever gizmo is
        // active (extrude in mesh-edit, translate in object mode) claims the
        // drag. A miss on both returns false and the camera takes the gesture.
        view.onGizmoMouseDown = { [weak self] p in self?.anyGizmoMouseDown(at: p) ?? false }
        view.onGizmoDragMove = { [weak self] p in self?.anyGizmoDragMoved(to: p) }
        view.onGizmoDragEnd = { [weak self] in self?.anyGizmoDragEnded() }
    }

    // MARK: Gizmo drag dispatch

    // coverage:disable — mouse-capture routing between RealityKit gizmos; exercised by the editor-harness translate-gizmo scenario, unreachable from unit tests (no NSView/ARView)
    private enum ActiveGizmoDrag { case extrude, translate, rotate, scale }
    private var activeGizmoDrag: ActiveGizmoDrag?

    private func anyGizmoMouseDown(at point: CGPoint) -> Bool {
        if gizmoDescriptor != nil, gizmoMouseDown(at: point) {
            activeGizmoDrag = .extrude
            return true
        }
        if translateDescriptor != nil, translateMouseDown(at: point) {
            activeGizmoDrag = .translate
            return true
        }
        if rotateDescriptor != nil, rotateMouseDown(at: point) {
            activeGizmoDrag = .rotate
            return true
        }
        if scaleDescriptor != nil, scaleMouseDown(at: point) {
            activeGizmoDrag = .scale
            return true
        }
        return false
    }

    private func anyGizmoDragMoved(to point: CGPoint) {
        switch activeGizmoDrag {
        case .extrude: gizmoDragMoved(to: point)
        case .translate: translateDragMoved(to: point)
        case .rotate: rotateDragMoved(to: point)
        case .scale: scaleDragMoved(to: point)
        case nil: break
        }
    }

    private func anyGizmoDragEnded() {
        switch activeGizmoDrag {
        case .extrude: gizmoDragEnded()
        case .translate: translateDragEnded()
        case .rotate: rotateDragEnded()
        case .scale: scaleDragEnded()
        case nil: break
        }
        activeGizmoDrag = nil
    }
    // coverage:enable

    func load(url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        loadTask?.cancel()
        baselinePrimPaths = nil
        appliedSceneRevision = nil
        loadedRoot = nil
        sceneApplier.reset()
        isLoading = url != nil
        // coverage:disable — animation-controller reset on model swap (golden-image tested)
        animationController = nil
        appliedAnimationTime = nil
        // coverage:enable
        modelAnchor.children.removeAll()
        onStats?(nil)
        onError?(nil)
        // No file: the stage is the only source of geometry, so every prim gets
        // synthesized by the `applyScene` that follows this call (a scratch
        // document built entirely from the library takes that path).
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
                self.loadedRoot = entity
                self.isLoading = false
                // The loader has already materialized every prim the file
                // contained, so adopt that as the diff baseline rather than
                // re-creating them; only prims the file lacked get synthesized.
                self.sceneApplier.seed(with: self.latestScene ?? ViewportScene())
                self.pruneModelEntities()
                self.reapplyLiveTransforms()
                // Re-establishes overrides and the active debug mode together
                // on the freshly loaded entity tree.
                self.reapplyDebugMode()
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
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

    // MARK: Snapshot-driven scene graph

    /// Renders the document's live scene: prims the loaded file never contained
    /// (library inserts, scripted or agent-authored prims) are materialized
    /// here, so the file seeds the viewport rather than defining it.
    ///
    /// While a load is in flight the scene is only recorded — applying it now
    /// would synthesize prims the loader is about to produce itself, and the
    /// completion handler seeds against the finished tree instead.
    func applyScene(_ scene: ViewportScene?) {
        guard let scene else { return }
        latestScene = scene
        guard !isLoading else { return }
        sceneApplier.apply(scene)
        frameSynthesizedContentIfNeeded()
    }

    /// Frames the camera the first time synthesized geometry appears with no
    /// file loaded — otherwise a shape added to an empty scene sits outside the
    /// default view. Only fires on the empty → non-empty transition, so later
    /// edits never yank the camera out from under the user.
    private func frameSynthesizedContentIfNeeded() {
        guard loadedRoot == nil, modelBounds == nil, !modelAnchor.children.isEmpty else { return }
        let bounds = modelAnchor.visualBounds(relativeTo: nil)
        guard bounds.boundingRadius > 1e-4 else { return }
        modelBounds = (bounds.center, bounds.boundingRadius)
        rebuildGrid(halfExtent: GridModel.fittingHalfExtent(forModelRadius: bounds.boundingRadius))
        frameModel()
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

    // MARK: Animation playback (transport-driven pose seeking)

    // coverage:disable — RealityKit AnimationResource glue, verified by golden-image tests (specs/testing.md layer 6)
    private var animationController: AnimationPlaybackController?
    private var appliedAnimationTime: Double?

    /// Seeks the loaded model's first available animation to `seconds` (from the
    /// clip start) and holds it paused there. Every transport action — play,
    /// scrub, loop, step — arrives as a new absolute time, so the viewport only
    /// ever "shows the pose at T" and never runs RealityKit's own clock. A `nil`
    /// time stops playback and returns the model to its rest pose.
    func applyAnimationTime(_ seconds: Double?) {
        guard seconds != appliedAnimationTime else { return }
        appliedAnimationTime = seconds
        guard let seconds else {
            animationController?.stop()
            animationController = nil
            return
        }
        if animationController == nil {
            animationController = startHeldAnimation()
        }
        guard let controller = animationController, controller.isValid else {
            animationController = nil
            return
        }
        // Clamp into the clip so scrubbing past the authored end holds the last
        // pose rather than snapping back to the start.
        let clamped = max(0, min(seconds, controller.duration))
        controller.time = clamped
        controller.pause()
    }

    /// Starts the first animation on any loaded entity, immediately paused, so
    /// `applyAnimationTime` can seek it. Returns `nil` when the model carries no
    /// animation.
    private func startHeldAnimation() -> AnimationPlaybackController? {
        for child in modelAnchor.children {
            if let controller = startHeldAnimation(on: child) { return controller }
        }
        return nil
    }

    private func startHeldAnimation(on entity: Entity) -> AnimationPlaybackController? {
        if let clip = entity.availableAnimations.first {
            let controller = entity.playAnimation(clip.repeat(), transitionDuration: 0,
                                                  startsPaused: true)
            return controller
        }
        for child in entity.children {
            if let controller = startHeldAnimation(on: child) { return controller }
        }
        return nil
    }
    // coverage:enable

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
        if debugMode == .shaded {
            reapplyMaterialOverrides()
        } else {
            // A debug mode owns the materials; fold the new overrides into the
            // clean base so `shaded` later restores the correct look.
            reapplyDebugMode()
        }
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

    // MARK: Environment & lighting (IBL presets, exposure, background)

    private var appliedEnvironment: EnvironmentSettings?

    /// Installs the resolved IBL source, exposure, and background onto the
    /// ARView (specs/viewport.md "Environment & Lighting"). Cheap when nothing
    /// changed (value-equality gated, same idiom as the other apply* methods).
    func applyEnvironment(_ settings: EnvironmentSettings) {
        guard settings != appliedEnvironment else { return }
        appliedEnvironment = settings
        guard let view else { return }

        // Lighting source.
        switch settings.resolvedSource {
        case .presetImage(let name):
            if let resource = try? EnvironmentResource.load(named: name) {
                view.environment.lighting.resource = resource
                if case .environment = settings.background {
                    view.environment.background = .skybox(resource)
                }
            }
        case .customFile(let url):
            let wantsSkybox: Bool = { if case .environment = settings.background { return true }; return false }()
            guard #available(macOS 15, *) else { break }
            Task { @MainActor [weak self, weak view] in
                guard let view, self?.appliedEnvironment?.resolvedSource == .customFile(url),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let resource = try? await EnvironmentResource(equirectangular: cgImage)
                else { return }
                view.environment.lighting.resource = resource
                if wantsSkybox { view.environment.background = .skybox(resource) }
            }
        case .constantColor(let color):
            let ns = Self.nsColor(color)
            if case .environment = settings.background {
                view.environment.background = .color(ns)
            }
        }

        // Exposure (EV) + intensity fold into RealityKit's intensity exponent.
        view.environment.lighting.intensityExponent =
            Float(settings.exposureEV) + log2(max(settings.intensity, 1e-4))

        // Non-environment backgrounds.
        switch settings.background {
        case .environment:
            break
        case .solidColor(let color):
            view.environment.background = .color(Self.nsColor(color))
        case .transparent:
            view.environment.background = .color(.clear)
        }
    }

    // MARK: Debug view modes (wireframe / normals / UV checker / matcap)

    private var debugMode: DebugViewMode = .shaded
    /// Pristine (or override) materials captured before a material-swap debug
    /// mode replaced them, keyed by entity identity, so `shaded` restores them.
    private var savedMaterials: [ObjectIdentifier: [any RealityFoundation.Material]] = [:]
    private let wireframeAnchor = AnchorEntity(world: .zero)
    /// Generated debug textures, built once and reused across mode toggles.
    private var debugTextureCache: [DebugMaterialSpec.Kind: TextureResource] = [:]
    /// Safety cap: skip wireframe generation for a mesh part above this edge
    /// count so the debug overlay never tanks a huge scene.
    private static let maxWireframeEdges = 200_000

    /// Switches the debug shading mode. Cheap when unchanged (mode-gated).
    func applyDebugMode(_ mode: DebugViewMode) {
        guard mode != debugMode else { return }
        debugMode = mode
        reapplyDebugMode()
    }

    /// Re-establishes the current debug mode from a clean base. Restores the
    /// saved materials, re-applies the user's material overrides on top, then
    /// layers the active debug mode (overlay for wireframe, material swap for
    /// the rest). Re-run after a model load or an override change.
    private func reapplyDebugMode() {
        restoreSavedMaterials()
        reapplyMaterialOverrides()
        clearWireframe()
        switch debugMode {
        case .shaded:
            break
        case .wireframe:
            buildWireframe()
        default:
            if let spec = debugMode.materialSpec { applyDebugMaterial(spec) }
        }
    }

    private func forEachModelEntity(_ body: (Entity) -> Void) {
        for child in modelAnchor.children {
            child.visit { if $0.components[ModelComponent.self] != nil { body($0) } }
        }
    }

    private func restoreSavedMaterials() {
        for (id, materials) in savedMaterials {
            forEachModelEntity { entity in
                guard ObjectIdentifier(entity) == id,
                      var model = entity.components[ModelComponent.self] else { return }
                model.materials = materials
                entity.components.set(model)
            }
        }
        savedMaterials.removeAll()
    }

    private func applyDebugMaterial(_ spec: DebugMaterialSpec) {
        guard let material = debugMaterial(spec) else { return }
        forEachModelEntity { entity in
            guard var model = entity.components[ModelComponent.self] else { return }
            let id = ObjectIdentifier(entity)
            if savedMaterials[id] == nil { savedMaterials[id] = model.materials }
            model.materials = Array(repeating: material, count: max(1, model.materials.count))
            entity.components.set(model)
        }
    }

    private func debugMaterial(_ spec: DebugMaterialSpec) -> (any RealityFoundation.Material)? {
        guard let texture = debugTexture(spec.kind) else { return nil }
        if spec.unlit {
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            return material
        }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = 0.7
        return material
    }

    private func debugTexture(_ kind: DebugMaterialSpec.Kind) -> TextureResource? {
        if let cached = debugTextureCache[kind] { return cached }
        let source = DebugTextureFactory.texture(for: kind, size: 256)
        guard let cgImage = Self.cgImage(from: source) else { return nil }
        // Normals/matcap carry raw colour (no colour-space transform); the UV
        // checker is a display-space colour texture.
        let semantic: TextureResource.Semantic = kind == .uvChecker ? .color : .raw
        guard let resource = try? TextureResource.generate(
            from: cgImage, options: .init(semantic: semantic)) else { return nil }
        debugTextureCache[kind] = resource
        return resource
    }

    private static func cgImage(from texture: DebugTexture) -> CGImage? {
        let data = Data(texture.rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: texture.width, height: texture.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func clearWireframe() {
        wireframeAnchor.children.removeAll()
        if wireframeAnchor.parent != nil { wireframeAnchor.removeFromParent() }
    }

    /// Builds a thin-box edge overlay for every projection mesh, in world space
    /// (so it tracks the entities' transforms), from the pure edge extraction.
    private func buildWireframe() {
        let material = UnlitMaterial(color: NSColor(white: 0.05, alpha: 0.9))
        var added = false
        forEachModelEntity { entity in
            guard let model = entity.components[ModelComponent.self] else { return }
            let world = entity.transformMatrix(relativeTo: nil)
            for part in model.mesh.contents.models.flatMap(\.parts) {
                guard let indices = part.triangleIndices.map(Array.init) else { continue }
                let positions = Array(part.positions)
                let edges = WireframeGeometry.uniqueEdges(triangleIndices: indices)
                guard edges.count <= Self.maxWireframeEdges else { continue }
                for edge in edges {
                    let i0 = Int(edge.x), i1 = Int(edge.y)
                    guard i0 < positions.count, i1 < positions.count else { continue }
                    let a = (world * SIMD4<Float>(positions[i0], 1))
                    let b = (world * SIMD4<Float>(positions[i1], 1))
                    if let box = Self.edgeBox(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z),
                                              material: material) {
                        wireframeAnchor.addChild(box)
                        added = true
                    }
                }
            }
        }
        if added, wireframeAnchor.parent == nil { view?.scene.addAnchor(wireframeAnchor) }
    }

    private static func edgeBox(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                material: UnlitMaterial) -> ModelEntity? {
        let dir = b - a
        let length = simd_length(dir)
        guard length > 1e-6 else { return nil }
        let thickness = max(length * 0.02, 1e-4)
        let box = ModelEntity(mesh: .generateBox(size: SIMD3(thickness, length, thickness)),
                              materials: [material])
        box.position = (a + b) / 2
        box.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir / length)
        return box
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
    /// BVH over the edit mesh; traversed per hover/click event. Rebuilt on a
    /// topology change, but during a position-only drag it is left `stale` and
    /// rebuilt lazily on the next pick — no pick happens mid-drag, so paying for
    /// an O(n log n) BVH build on every pointer event is pure waste.
    private var pickAccelerator: PickAccelerator?
    private var pickAcceleratorIsStale = false
    /// The live edit-mesh entities, retained so a position-only drag update can
    /// swap their geometry in place instead of tearing the anchor down and
    /// re-instantiating entities + materials every pointer event.
    private var editBaseEntity: ModelEntity?
    private var editHighlightEntity: ModelEntity?

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
        let previous = editData
        editData = data

        guard let data else {
            // Exit edit mode: full teardown.
            pickAccelerator = nil
            pickAcceleratorIsStale = false
            editBaseEntity = nil
            editHighlightEntity = nil
            setHoveredFace(nil)
            editAnchor.children.removeAll()
            hoverEntity = nil
            hiddenOriginal?.isEnabled = true
            hiddenOriginal = nil
            if editAnchor.parent != nil { editAnchor.removeFromParent() }
            return
        }

        switch data.update(from: previous) {
        case .none:
            // Only the revision counter churned — geometry, selection and prim
            // are all unchanged, so there is nothing to redraw and the BVH still
            // matches. This is the cheapest possible drag frame.
            return
        case .positions where editBaseEntity != nil:
            // Interactive extrude/inset drag: vertices moved but topology and
            // selection held. Refresh the existing entities' geometry in place
            // and mark the BVH stale (rebuilt lazily on the next pick) — no
            // teardown, no re-instantiation, no per-event BVH build.
            pickAcceleratorIsStale = true
            setHoveredFace(nil) // positions moved; a stale hover face would mislead
            if let mesh = Self.meshResource(MeshFlattener.flatten(data)) {
                editBaseEntity?.model?.mesh = mesh
            }
            if !data.selectedFaces.isEmpty,
               let highlight = Self.meshResource(
                MeshFlattener.flatten(data, faces: data.selectedFaces.sorted()), inflate: 0.003) {
                editHighlightEntity?.model?.mesh = highlight
            }
            return
        case .positions, .rebuild:
            break // fall through to a full rebuild
        }

        // Full rebuild: topology, selection or prim identity changed (or this is
        // the first frame of an edit session).
        pickAccelerator = PickAccelerator(data)
        pickAcceleratorIsStale = false
        setHoveredFace(nil) // geometry changed; stale hover would mislead
        editAnchor.children.removeAll()
        editBaseEntity = nil
        editHighlightEntity = nil
        hoverEntity = nil

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
            editBaseEntity = entity // retained for in-place position-only updates
        }
        if !data.selectedFaces.isEmpty,
           let highlight = Self.meshResource(
            MeshFlattener.flatten(data, faces: data.selectedFaces.sorted()), inflate: 0.003) {
            let entity = ModelEntity(
                mesh: highlight,
                materials: [UnlitMaterial(color: NSColor(srgbRed: 0.91, green: 0.7, blue: 0.25, alpha: 0.55))])
            entity.transform = Transform(matrix: worldMatrix)
            editAnchor.addChild(entity)
            editHighlightEntity = entity // retained for in-place position-only updates
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
        guard let data = editData, let ray = primLocalRay(at: point) else { return nil }
        // A position-only drag left the BVH stale; rebuild it now, at the first
        // pick after the drag, so it reflects the current vertex positions.
        if pickAcceleratorIsStale {
            pickAccelerator = PickAccelerator(data)
            pickAcceleratorIsStale = false
        }
        return (pickAccelerator?.pickFace(ray: ray) ?? MeshPicker.pickFace(ray: ray, in: data))?.faceIndex
    }

    /// Click point → world pick ray → the edited prim's local space (where the
    /// edit mesh, selection overlays, and extrude gizmo all live). Direction is
    /// NOT re-normalized: keeping the world-ray parameterization means axis
    /// parameters measured on this ray stay proportional to local units.
    private func primLocalRay(at point: CGPoint) -> CameraRay.Ray? {
        guard let view,
              let ray = CameraRay.make(camera: camera, viewSize: view.bounds.size, point: point)
        else { return nil }
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4
        let inverse = worldMatrix.inverse
        let origin4 = inverse * SIMD4<Float>(SIMD3<Float>(ray.origin), 1)
        let dir4 = inverse * SIMD4<Float>(SIMD3<Float>(ray.direction), 0)
        let direction = SIMD3<Double>(SIMD3(dir4.x, dir4.y, dir4.z))
        let len = (direction * direction).sum().squareRoot()
        guard len > 1e-12 else { return nil }
        return CameraRay.Ray(origin: SIMD3<Double>(SIMD3(origin4.x, origin4.y, origin4.z)),
                             direction: direction / len)
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

    // MARK: Extrude gizmo (drag-to-extrude handle; specs/mesh-editing.md)

    /// Container carrying the prim's world transform; `gizmoHandle` inside it
    /// lives in prim-local space like the edit mesh and selection overlays.
    private let gizmoRoot = Entity()
    private let gizmoHandle = Entity()
    private var gizmoDescriptor: ExtrudeGizmoDescriptor?
    private var onGizmoDrag: ((ExtrudeGizmoDragPhase) -> Void)?
    /// Drag reference frozen at mouse-down: the handle's origin/axis and the
    /// start ray's axis parameter. The live preview moves the handle, but the
    /// drag keeps measuring against where it was grabbed — no feedback loop.
    private var gizmoDragStart: (origin: SIMD3<Double>, axis: SIMD3<Double>, param: Double)?
    private var gizmoLastDistance = 0.0

    /// Shows/hides/rebuilds the extrude handle. Cheap when unchanged
    /// (descriptor-gated, same idiom as the other apply* methods).
    func applyExtrudeGizmo(_ descriptor: ExtrudeGizmoDescriptor?,
                           onDrag: ((ExtrudeGizmoDragPhase) -> Void)?) {
        onGizmoDrag = onDrag
        let active = descriptor != nil
        // `applyEditedMesh` clears the edit anchor on every mesh revision, so
        // reattach even when the descriptor itself is unchanged.
        if let current = descriptor ?? gizmoDescriptor, gizmoRoot.parent == nil, active {
            if gizmoHandle.parent == nil { gizmoRoot.addChild(gizmoHandle) }
            editAnchor.addChild(gizmoRoot)
            if editAnchor.parent == nil { view?.scene.addAnchor(editAnchor) }
            layoutGizmo(current)
        }
        guard descriptor != gizmoDescriptor else { return }
        gizmoDescriptor = descriptor
        guard let descriptor else {
            gizmoDragStart = nil
            gizmoRoot.removeFromParent()
            return
        }
        if gizmoHandle.children.isEmpty { rebuildGizmoGeometry() }
        layoutGizmo(descriptor)
    }

    /// Unit-length arrow (shaft + tip sphere) along +Y; `layoutGizmo` scales it
    /// to screen-constant size and aims it down the extrude axis. Amber to
    /// match the selection it extrudes; unlit so it reads at any angle.
    private func rebuildGizmoGeometry() {
        gizmoHandle.children.removeAll()
        let shaftColor = NSColor(srgbRed: 0.91, green: 0.7, blue: 0.25, alpha: 0.95)
        let r = Float(ExtrudeGizmoMath.shaftRadiusFraction)
        let shaft = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(r * 2, 1, r * 2)),
                                materials: [UnlitMaterial(color: shaftColor)])
        shaft.position = SIMD3<Float>(0, 0.5, 0)
        let tip = ModelEntity(mesh: .generateSphere(radius: Float(ExtrudeGizmoMath.tipRadiusFraction)),
                              materials: [UnlitMaterial(color: shaftColor)])
        tip.position = SIMD3<Float>(0, 1, 0)
        gizmoHandle.addChild(shaft)
        gizmoHandle.addChild(tip)
    }

    /// Anchors the handle at the selection centroid, aims it along the extrude
    /// axis, and scales it to a constant apparent size for the current camera
    /// distance (re-run on every camera change).
    private func layoutGizmo(_ descriptor: ExtrudeGizmoDescriptor) {
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4
        gizmoRoot.transform = Transform(matrix: worldMatrix)
        gizmoHandle.position = SIMD3<Float>(descriptor.origin)
        gizmoHandle.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0),
                                             to: simd_normalize(SIMD3<Float>(descriptor.axis)))
        gizmoHandle.scale = SIMD3<Float>(repeating: Float(gizmoLocalLength()))
    }

    /// Handle length in prim-local units: world screen-constant length divided
    /// by the prim's (approximately uniform) world scale.
    private func gizmoLocalLength() -> Double {
        let worldMatrix = hiddenOriginal?.parent?.transformMatrix(relativeTo: nil)
            ?? matrix_identity_float4x4
        let scaleColumn = worldMatrix.columns.0
        let worldScale = Double(simd_length(SIMD3(scaleColumn.x, scaleColumn.y, scaleColumn.z)))
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        return worldScale > 1e-9 ? length / worldScale : length
    }

    /// Mouse-down over the handle? Then capture the drag (camera stays put).
    private func gizmoMouseDown(at point: CGPoint) -> Bool {
        guard let descriptor = gizmoDescriptor, let ray = primLocalRay(at: point),
              ExtrudeGizmoMath.hitTest(ray: ray, origin: descriptor.origin,
                                       axis: descriptor.axis, length: gizmoLocalLength()),
              let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: descriptor.origin,
                                                         axis: descriptor.axis)
        else { return false }
        gizmoDragStart = (descriptor.origin, descriptor.axis, param)
        gizmoLastDistance = 0
        setHoveredFace(nil) // hover highlight would fight the live preview
        onGizmoDrag?(.began)
        return true
    }

    private func gizmoDragMoved(to point: CGPoint) {
        guard let start = gizmoDragStart else { return }
        // A ray gone parallel to the axis keeps the last stable distance
        // instead of jumping — the drag freezes, never glitches.
        if let ray = primLocalRay(at: point),
           let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: start.origin,
                                                      axis: start.axis) {
            gizmoLastDistance = param - start.param
        }
        onGizmoDrag?(.changed(gizmoLastDistance))
    }

    private func gizmoDragEnded() {
        guard gizmoDragStart != nil else { return }
        gizmoDragStart = nil
        onGizmoDrag?(.ended)
    }

    // MARK: Translate gizmo (object-mode XYZ move arrows)

    // coverage:disable — RealityKit arrow rendering + drag glue; the math is unit-tested (TranslateGizmoMathTests) and the document flow by the editor-harness translate-gizmo scenario
    /// World-space container for the three arrows; positioned at the
    /// selection's world pivot and scaled to screen-constant size.
    private let translateAnchor = AnchorEntity(world: .zero)
    private let translateRoot = Entity()
    private var translateDescriptor: TranslateGizmoDescriptor?
    private var onTranslateGizmoDrag: ((TranslateGizmoDragPhase) -> Void)?
    /// The shaft+tip models per axis (rawValue-keyed) for drag highlighting.
    private var translateArrowModels: [Int: [ModelEntity]] = [:]
    /// Drag reference frozen at mouse-down (same no-feedback-loop idiom as the
    /// extrude handle): the grabbed axis, the pivot at grab time, and the
    /// start ray's axis parameter.
    private var translateDragStart: (axis: GizmoAxis, origin: SIMD3<Double>, param: Double)?
    private var translateLastDistance = 0.0

    /// DCC-standard axis tints (matching the grid/orientation gizmo):
    /// X red, Y green, Z blue.
    private static let axisColors: [NSColor] = [
        NSColor(srgbRed: 0.91, green: 0.34, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.83, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.34, green: 0.55, blue: 0.98, alpha: 1),
    ]
    private static let activeAxisColor = NSColor(srgbRed: 0.98, green: 0.86, blue: 0.25, alpha: 1)

    /// Shows/hides/re-lays-out the move gizmo (descriptor-gated like the other
    /// apply* methods; the revision bump on every edit keeps it following the
    /// object it moves).
    func applyTranslateGizmo(_ descriptor: TranslateGizmoDescriptor?,
                             onDrag: ((TranslateGizmoDragPhase) -> Void)?) {
        onTranslateGizmoDrag = onDrag
        guard descriptor != translateDescriptor else { return }
        translateDescriptor = descriptor
        guard let descriptor else {
            translateDragStart = nil
            translateAnchor.removeFromParent()
            return
        }
        if translateRoot.parent == nil { translateAnchor.addChild(translateRoot) }
        if translateAnchor.parent == nil { view?.scene.addAnchor(translateAnchor) }
        if translateRoot.children.isEmpty { rebuildTranslateGizmoGeometry() }
        layoutTranslateGizmo(descriptor)
    }

    /// Three unit-length arrows (cylinder shaft + cone tip) built along +Y and
    /// aimed down each axis; `layoutTranslateGizmo` scales the whole root to a
    /// screen-constant size. Unlit so they read at any angle.
    private func rebuildTranslateGizmoGeometry() {
        translateRoot.children.removeAll()
        translateArrowModels = [:]
        let shaftRadius = Float(ExtrudeGizmoMath.shaftRadiusFraction)
        // Cylinder/cone primitives are macOS 15+; box shaft + sphere tip is
        // the same fallback the extrude handle uses.
        let shaftMesh: MeshResource
        let tipMesh: MeshResource
        if #available(macOS 15.0, *) {
            shaftMesh = .generateCylinder(height: 0.78, radius: shaftRadius)
            tipMesh = .generateCone(height: 0.22, radius: 0.06)
        } else {
            shaftMesh = .generateBox(size: SIMD3<Float>(shaftRadius * 2, 0.78, shaftRadius * 2))
            tipMesh = .generateSphere(radius: 0.07)
        }
        for axis in GizmoAxis.allCases {
            let material = UnlitMaterial(color: Self.axisColors[axis.rawValue])
            let shaft = ModelEntity(mesh: shaftMesh, materials: [material])
            shaft.position = SIMD3<Float>(0, 0.39, 0)
            let tip = ModelEntity(mesh: tipMesh, materials: [material])
            tip.position = SIMD3<Float>(0, 0.89, 0)
            let arrow = Entity()
            arrow.addChild(shaft)
            arrow.addChild(tip)
            arrow.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0),
                                           to: SIMD3<Float>(axis.direction))
            translateRoot.addChild(arrow)
            translateArrowModels[axis.rawValue] = [shaft, tip]
        }
    }

    /// Anchors the arrows at the selection pivot and scales them to a constant
    /// apparent size for the current camera distance (re-run on every camera
    /// change, like the extrude handle).
    private func layoutTranslateGizmo(_ descriptor: TranslateGizmoDescriptor) {
        translateRoot.position = SIMD3<Float>(descriptor.origin)
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        translateRoot.scale = SIMD3<Float>(repeating: Float(length))
    }

    /// Tints the dragged axis's arrow the active (yellow) colour; `nil`
    /// restores all three to their axis tints.
    private func setTranslateHighlight(_ axis: GizmoAxis?) {
        for a in GizmoAxis.allCases {
            let color = a == axis ? Self.activeAxisColor : Self.axisColors[a.rawValue]
            for model in translateArrowModels[a.rawValue] ?? [] {
                model.model?.materials = [UnlitMaterial(color: color)]
            }
        }
    }

    /// The click's pick ray in world space (the move gizmo lives in world
    /// space, unlike the prim-local extrude handle).
    private func worldRay(at point: CGPoint) -> CameraRay.Ray? {
        guard let view else { return nil }
        return CameraRay.make(camera: camera, viewSize: view.bounds.size, point: point)
    }

    /// Mouse-down over an arrow? Then capture the drag (camera stays put).
    private func translateMouseDown(at point: CGPoint) -> Bool {
        guard let descriptor = translateDescriptor, let ray = worldRay(at: point) else { return false }
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        guard let axis = TranslateGizmoMath.hitAxis(ray: ray, origin: descriptor.origin,
                                                    length: length),
              let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: descriptor.origin,
                                                         axis: axis.direction)
        else { return false }
        translateDragStart = (axis, descriptor.origin, param)
        translateLastDistance = 0
        setTranslateHighlight(axis)
        onTranslateGizmoDrag?(.began(axis))
        return true
    }

    private func translateDragMoved(to point: CGPoint) {
        guard let start = translateDragStart else { return }
        // A ray gone parallel to the axis keeps the last stable distance
        // instead of jumping — the drag freezes, never glitches.
        if let ray = worldRay(at: point),
           let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: start.origin,
                                                      axis: start.axis.direction) {
            translateLastDistance = param - start.param
        }
        onTranslateGizmoDrag?(.changed(start.axis, translateLastDistance))
    }

    private func translateDragEnded() {
        guard translateDragStart != nil else { return }
        translateDragStart = nil
        setTranslateHighlight(nil)
        onTranslateGizmoDrag?(.ended)
    }
    // coverage:enable

    // MARK: Rotate gizmo (object-mode XYZ rings)

    // coverage:disable — RealityKit ring rendering + drag glue; the math is unit-tested (RotateGizmoMathTests) and the document flow by the rotate/scale gizmo document tests
    private let rotateAnchor = AnchorEntity(world: .zero)
    private let rotateRoot = Entity()
    private var rotateDescriptor: RotateGizmoDescriptor?
    private var onRotateGizmoDrag: ((RotateGizmoDragPhase) -> Void)?
    private var rotateRingModels: [Int: [ModelEntity]] = [:]
    /// Grab reference frozen at mouse-down: the ring's axis, the pivot, the
    /// axis world direction, and the ray that started the drag (the swept angle
    /// is measured from it every frame).
    private var rotateDragStart: (axis: GizmoAxis, origin: SIMD3<Double>,
                                  normal: SIMD3<Double>, startRay: CameraRay.Ray)?
    private var rotateLastAngle = 0.0

    func applyRotateGizmo(_ descriptor: RotateGizmoDescriptor?,
                          onDrag: ((RotateGizmoDragPhase) -> Void)?) {
        onRotateGizmoDrag = onDrag
        guard descriptor != rotateDescriptor else { return }
        rotateDescriptor = descriptor
        guard let descriptor else {
            rotateDragStart = nil
            rotateAnchor.removeFromParent()
            return
        }
        if rotateRoot.parent == nil { rotateAnchor.addChild(rotateRoot) }
        if rotateAnchor.parent == nil { view?.scene.addAnchor(rotateAnchor) }
        rebuildRotateGizmoGeometry(descriptor.basis)
        layoutRotateGizmo(descriptor)
    }

    /// Three axis rings (thin box segments swept into a circle), each oriented
    /// so its plane normal points along the corresponding basis axis.
    private func rebuildRotateGizmoGeometry(_ basis: GizmoBasis) {
        rotateRoot.children.removeAll()
        rotateRingModels = [:]
        for axis in GizmoAxis.allCases {
            let normal = simd_normalize(SIMD3<Float>(basis.direction(axis)))
            let (ring, models) = Self.makeRing(normal: normal,
                                               color: Self.axisColors[axis.rawValue])
            rotateRoot.addChild(ring)
            rotateRingModels[axis.rawValue] = models
        }
    }

    private static func makeRing(normal: SIMD3<Float>, color: NSColor) -> (Entity, [ModelEntity]) {
        let ring = Entity()
        var models: [ModelEntity] = []
        let segments = 48
        let radius = Float(RotateGizmoMath.radiusFraction)
        let thickness: Float = 0.025
        let material = UnlitMaterial(color: color)
        let arc = 2 * Float.pi * radius / Float(segments) * 1.15
        let mesh = MeshResource.generateBox(size: SIMD3<Float>(thickness, thickness, arc))
        for i in 0..<segments {
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            let seg = ModelEntity(mesh: mesh, materials: [material])
            seg.position = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius, 0)
            seg.orientation = simd_quatf(angle: angle + .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            ring.addChild(seg)
            models.append(seg)
        }
        ring.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)
        return (ring, models)
    }

    private func layoutRotateGizmo(_ descriptor: RotateGizmoDescriptor) {
        rotateRoot.position = SIMD3<Float>(descriptor.origin)
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        rotateRoot.scale = SIMD3<Float>(repeating: Float(length))
    }

    private func setRotateHighlight(_ axis: GizmoAxis?) {
        for a in GizmoAxis.allCases {
            let color = a == axis ? Self.activeAxisColor : Self.axisColors[a.rawValue]
            for model in rotateRingModels[a.rawValue] ?? [] {
                model.model?.materials = [UnlitMaterial(color: color)]
            }
        }
    }

    private func rotateMouseDown(at point: CGPoint) -> Bool {
        guard let descriptor = rotateDescriptor, let ray = worldRay(at: point) else { return false }
        let radius = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
            * RotateGizmoMath.radiusFraction
        guard let axis = RotateGizmoMath.hitAxis(ray: ray, origin: descriptor.origin,
                                                 basis: descriptor.basis, radius: radius)
        else { return false }
        rotateDragStart = (axis, descriptor.origin,
                           simd_normalize(descriptor.basis.direction(axis)), ray)
        rotateLastAngle = 0
        setRotateHighlight(axis)
        onRotateGizmoDrag?(.began(axis))
        return true
    }

    private func rotateDragMoved(to point: CGPoint) {
        guard let start = rotateDragStart else { return }
        if let ray = worldRay(at: point),
           let angle = RotateGizmoMath.signedAngleDegrees(from: start.startRay, to: ray,
                                                          origin: start.origin, axis: start.normal) {
            rotateLastAngle = angle
        }
        onRotateGizmoDrag?(.changed(start.axis, rotateLastAngle))
    }

    private func rotateDragEnded() {
        guard rotateDragStart != nil else { return }
        rotateDragStart = nil
        setRotateHighlight(nil)
        onRotateGizmoDrag?(.ended)
    }
    // coverage:enable

    // MARK: Scale gizmo (object-mode box handles + uniform centre)

    // coverage:disable — RealityKit box rendering + drag glue; the math is unit-tested (ScaleGizmoMathTests) and the document flow by the rotate/scale gizmo document tests
    private let scaleAnchor = AnchorEntity(world: .zero)
    private let scaleRoot = Entity()
    private var scaleDescriptor: ScaleGizmoDescriptor?
    private var onScaleGizmoDrag: ((ScaleGizmoDragPhase) -> Void)?
    private var scaleHandleModels: [Int: ModelEntity] = [:]
    private var scaleUniformModel: ModelEntity?
    /// Grab reference: the handle, the pivot, the world axis the drag is
    /// measured along, and the axis parameter at grab time (factor = current /
    /// start, per `ScaleGizmoMath.factor`).
    private var scaleDragStart: (handle: ScaleHandle, origin: SIMD3<Double>,
                                 axis: SIMD3<Double>, param: Double)?
    private var scaleLastFactor = 1.0

    func applyScaleGizmo(_ descriptor: ScaleGizmoDescriptor?,
                         onDrag: ((ScaleGizmoDragPhase) -> Void)?) {
        onScaleGizmoDrag = onDrag
        guard descriptor != scaleDescriptor else { return }
        scaleDescriptor = descriptor
        guard let descriptor else {
            scaleDragStart = nil
            scaleAnchor.removeFromParent()
            return
        }
        if scaleRoot.parent == nil { scaleAnchor.addChild(scaleRoot) }
        if scaleAnchor.parent == nil { view?.scene.addAnchor(scaleAnchor) }
        rebuildScaleGizmoGeometry(descriptor.basis)
        layoutScaleGizmo(descriptor)
    }

    /// Three per-axis stalks capped with a box handle, plus a central uniform
    /// cube, built along each basis axis.
    private func rebuildScaleGizmoGeometry(_ basis: GizmoBasis) {
        scaleRoot.children.removeAll()
        scaleHandleModels = [:]
        let shaftRadius = Float(ExtrudeGizmoMath.shaftRadiusFraction)
        let shaftMesh: MeshResource = {
            if #available(macOS 15.0, *) {
                return .generateCylinder(height: 0.8, radius: shaftRadius)
            } else {
                return .generateBox(size: SIMD3<Float>(shaftRadius * 2, 0.8, shaftRadius * 2))
            }
        }()
        let tipMesh = MeshResource.generateBox(size: 0.14)
        for axis in GizmoAxis.allCases {
            let material = UnlitMaterial(color: Self.axisColors[axis.rawValue])
            let shaft = ModelEntity(mesh: shaftMesh, materials: [material])
            shaft.position = SIMD3<Float>(0, 0.4, 0)
            let tip = ModelEntity(mesh: tipMesh, materials: [material])
            tip.position = SIMD3<Float>(0, 0.9, 0)
            let arm = Entity()
            arm.addChild(shaft)
            arm.addChild(tip)
            arm.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0),
                                         to: simd_normalize(SIMD3<Float>(basis.direction(axis))))
            scaleRoot.addChild(arm)
            scaleHandleModels[axis.rawValue] = tip
        }
        let centre = ModelEntity(mesh: .generateBox(size: 0.2),
                                 materials: [UnlitMaterial(color: Self.uniformColor)])
        scaleRoot.addChild(centre)
        scaleUniformModel = centre
    }

    private func layoutScaleGizmo(_ descriptor: ScaleGizmoDescriptor) {
        scaleRoot.position = SIMD3<Float>(descriptor.origin)
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        scaleRoot.scale = SIMD3<Float>(repeating: Float(length))
    }

    private static let uniformColor = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1)

    private func setScaleHighlight(_ handle: ScaleHandle?) {
        for a in GizmoAxis.allCases {
            let active = handle == .axis(a)
            scaleHandleModels[a.rawValue]?.model?.materials =
                [UnlitMaterial(color: active ? Self.activeAxisColor : Self.axisColors[a.rawValue])]
        }
        let uniformActive = handle == .uniform
        scaleUniformModel?.model?.materials =
            [UnlitMaterial(color: uniformActive ? Self.activeAxisColor : Self.uniformColor)]
    }

    /// The world axis a uniform drag is measured along — the camera's right
    /// vector, so left/right cursor motion grows/shrinks the object.
    private func cameraRightAxis() -> SIMD3<Double> {
        let forward = camera.target - camera.position
        let right = simd_cross(forward, SIMD3<Double>(0, 1, 0))
        let len = simd_length(right)
        return len > 1e-9 ? right / len : SIMD3<Double>(1, 0, 0)
    }

    private func scaleMouseDown(at point: CGPoint) -> Bool {
        guard let descriptor = scaleDescriptor, let ray = worldRay(at: point) else { return false }
        let length = ExtrudeGizmoMath.handleLength(cameraDistance: camera.distance)
        guard let handle = ScaleGizmoMath.hitHandle(ray: ray, origin: descriptor.origin,
                                                    basis: descriptor.basis, length: length)
        else { return false }
        let axis: SIMD3<Double> = switch handle {
        case .uniform: cameraRightAxis()
        case let .axis(a): simd_normalize(descriptor.basis.direction(a))
        }
        guard let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: descriptor.origin,
                                                         axis: axis) else { return false }
        // The tip sits ~one handle-length out; seed the reference at that
        // radius so a static click reads factor 1 even when param starts small.
        let seed = abs(param) > length * 0.25 ? param : (param < 0 ? -length : length)
        scaleDragStart = (handle, descriptor.origin, axis, seed)
        scaleLastFactor = 1
        setScaleHighlight(handle)
        onScaleGizmoDrag?(.began(handle))
        return true
    }

    private func scaleDragMoved(to point: CGPoint) {
        guard let start = scaleDragStart else { return }
        if let ray = worldRay(at: point),
           let param = ExtrudeGizmoMath.axisParameter(ray: ray, origin: start.origin, axis: start.axis),
           let factor = ScaleGizmoMath.factor(fromParam: start.param, toParam: param) {
            scaleLastFactor = max(0.01, factor)
        }
        onScaleGizmoDrag?(.changed(start.handle, scaleLastFactor))
    }

    private func scaleDragEnded() {
        guard scaleDragStart != nil else { return }
        scaleDragStart = nil
        setScaleHighlight(nil)
        onScaleGizmoDrag?(.ended)
    }
    // coverage:enable

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
        // Keep the gizmo handles a constant apparent size as the camera moves.
        if let descriptor = gizmoDescriptor { layoutGizmo(descriptor) }
        if let descriptor = translateDescriptor { layoutTranslateGizmo(descriptor) }
        if let descriptor = rotateDescriptor { layoutRotateGizmo(descriptor) }
        if let descriptor = scaleDescriptor { layoutScaleGizmo(descriptor) }
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
    /// Tab toggles object ⇄ mesh edit mode (Blender muscle memory). Handled here
    /// in `keyDown` — while the viewport is first responder AppKit consumes bare
    /// Tab for its key-view loop before it ever reaches the SwiftUI
    /// `keyboardShortcut(.tab)` fallback, so the hotkey has to be caught on the
    /// responder that actually has focus. `nil` outside edit-capable hosts.
    var onToggleEditMode: (() -> Void)?
    /// Component picking in edit mode: fires with the click point in top-left
    /// view coordinates when a press releases without dragging. The Bool is
    /// `true` when ⇧ was held (additive multi-select).
    var onEditClick: ((CGPoint, Bool) -> Void)?
    /// Live hover preview in edit mode: fires with the cursor point (top-left
    /// coordinates) on every move, and `nil`-equivalent via mouseExited.
    var onHoverMove: ((CGPoint) -> Void)? {
        didSet { updateTrackingAreas() }
    }

    /// Extrude-gizmo drag capture: `onGizmoMouseDown` hit-tests the handle at
    /// press time and returns `true` to claim the drag — the camera then never
    /// sees it. Move/end phases follow on the same capture. Points arrive in
    /// top-left coordinates like the picking callbacks.
    var onGizmoMouseDown: ((CGPoint) -> Bool)?
    var onGizmoDragMove: ((CGPoint) -> Void)?
    var onGizmoDragEnd: (() -> Void)?

    private var mouseDownPoint: CGPoint?
    private var dragged = false
    private var gizmoCapturing = false
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
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        dragged = false
        // Handle grab wins over camera and picking for the whole gesture.
        gizmoCapturing = onGizmoMouseDown?(CGPoint(x: p.x, y: bounds.height - p.y)) ?? false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if gizmoCapturing {
            gizmoCapturing = false
            onGizmoDragEnd?()
            return
        }
        guard !dragged, let onEditClick, let down = mouseDownPoint else { return }
        let up = convert(event.locationInWindow, from: nil)
        guard abs(up.x - down.x) < 3, abs(up.y - down.y) < 3 else { return }
        // AppKit's origin is bottom-left; picking math wants top-left.
        onEditClick(CGPoint(x: up.x, y: bounds.height - up.y),
                    event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if gizmoCapturing {
            let p = convert(event.locationInWindow, from: nil)
            onGizmoDragMove?(CGPoint(x: p.x, y: bounds.height - p.y))
            return
        }
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
        // Tab (keyCode 48) toggles edit mode. Match on keyCode rather than the
        // character so a remapped field-editor Tab can't slip past, and swallow
        // the event (no `super`) so AppKit doesn't also run its key-view loop.
        if event.keyCode == 48, let onToggleEditMode {
            onToggleEditMode()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": onFrame?()
        default: super.keyDown(with: event)
        }
    }
}
#endif
