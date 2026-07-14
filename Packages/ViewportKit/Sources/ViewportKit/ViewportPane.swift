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
}

public struct ViewportPane: View {

    let modelURL: URL?
    @State private var stats: SceneStats?
    @State private var showStats = true
    @State private var loadError: String?
    @State private var cameraMode: CameraInteractionMode = .rotate

    public init(modelURL: URL?) {
        self.modelURL = modelURL
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewportRepresentable(modelURL: modelURL, mode: cameraMode, stats: $stats, loadError: $loadError)
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
                    .help(mode.label)
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

    /// Camera action a plain drag performs; driven by the top-leading buttons.
    var interactionMode: CameraInteractionMode = .rotate

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
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
