#if os(macOS)
import SwiftUI
import RealityKit
import AppKit
import Combine
#endif
import simd

/// Pure, platform-free math for the library shape preview (`ShapePreviewView`).
/// Split out from the RealityKit glue so framing and turntable behaviour stay
/// unit-testable without an `ARView` (specs/testing.md).
public enum ShapePreviewMath {

    /// Axis-aligned bounds of a point cloud as a centre + bounding-sphere
    /// radius. `nil` for an empty cloud (nothing to frame). The radius is the
    /// farthest corner distance from the centre, so a camera framed to it never
    /// clips the geometry regardless of orientation.
    public static func bounds(of positions: [SIMD3<Float>]) -> (center: SIMD3<Float>, radius: Float)? {
        guard var lo = positions.first, var hi = positions.first else { return nil }
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let center = (lo + hi) / 2
        let radius = simd_length(hi - center)
        return (center, max(radius, 1e-5))
    }

    /// Distance a perspective camera (vertical FOV `OrbitCamera.verticalFOV`)
    /// must sit from a sphere of `radius` for it to fill the frame with a small
    /// margin. `margin` is a multiplier on the radius (1.1 ≈ 10 % padding), so
    /// the shape never touches the preview's edges.
    public static func framingDistance(radius: Double, margin: Double = 1.15) -> Double {
        let r = max(radius, 1e-6) * max(margin, 1)
        return r / tan(OrbitCamera.verticalFOV / 2)
    }

    /// Turntable rotation angle (radians) at `elapsed` seconds. Wrapped into
    /// `[0, 2π)` so the value stays bounded over a long-running preview and the
    /// motion is exactly periodic.
    public static func turntableAngle(elapsed: Double, radiansPerSecond: Double) -> Double {
        let twoPi = 2 * Double.pi
        let raw = elapsed * radiansPerSecond
        let wrapped = raw.truncatingRemainder(dividingBy: twoPi)
        return wrapped < 0 ? wrapped + twoPi : wrapped
    }
}

#if os(macOS)

/// A compact, self-contained 3D preview of a single library shape: the mesh on
/// a slow turntable, framed to fill the panel. Replaces the old text-heavy
/// library detail pane with something you can actually read at a glance.
///
/// Optimized by construction: one lightweight `ARView` reused across selection
/// changes (the mesh resource is swapped, never the view), the turntable driven
/// by RealityKit's own render-loop tick rather than a `Timer`, and the built
/// `MeshResource` cached by identity so re-selecting a shape never re-tessellates.
public struct ShapePreviewView: View {
    /// Geometry to show. `nil` renders an empty stage (no selection).
    let mesh: ViewportMeshData?
    /// Stable identity of `mesh`, so the coordinator can tell a genuine geometry
    /// change from a redundant SwiftUI update and skip rebuilding when equal.
    let identity: String?
    /// Turntable speed; 0 holds the shape still.
    let radiansPerSecond: Double

    public init(mesh: ViewportMeshData?, identity: String?, radiansPerSecond: Double = 0.6) {
        self.mesh = mesh
        self.identity = identity
        self.radiansPerSecond = radiansPerSecond
    }

    public var body: some View {
        ShapePreviewRepresentable(mesh: mesh, identity: identity,
                                  radiansPerSecond: radiansPerSecond)
    }
}

// coverage:disable — RealityKit/AppKit rendering glue; the framing/turntable
// math it drives (ShapePreviewMath) is unit-tested separately (specs/testing.md).

struct ShapePreviewRepresentable: NSViewRepresentable {
    let mesh: ViewportMeshData?
    let identity: String?
    let radiansPerSecond: Double

    func makeCoordinator() -> ShapePreviewCoordinator { ShapePreviewCoordinator() }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        context.coordinator.radiansPerSecond = radiansPerSecond
        context.coordinator.update(mesh: mesh, identity: identity)
    }

    static func dismantleNSView(_ view: ARView, coordinator: ShapePreviewCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class ShapePreviewCoordinator {
    private weak var view: ARView?
    private let modelAnchor = AnchorEntity(world: .zero)
    private let cameraAnchor = AnchorEntity(world: .zero)
    private let cameraEntity = PerspectiveCamera()
    /// The recentred shape that the turntable spins; `nil` when nothing shown.
    private var spinTarget: Entity?
    private var updateSubscription: (any Combine.Cancellable)?

    /// Identity of the mesh currently on screen, so a redundant SwiftUI pass
    /// (same shape, unrelated state change) doesn't rebuild the entity.
    private var currentIdentity: String?
    /// Built meshes kept by identity — re-selecting a shape reuses its resource
    /// rather than re-tessellating the half-edge geometry.
    private var meshCache: [String: MeshResource] = [:]
    /// Accumulated turntable angle (radians), advanced each render tick.
    private var angle: Double = 0
    var radiansPerSecond: Double = 0.6

    func attach(to view: ARView) {
        self.view = view
        view.environment.background = .color(NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1))
        cameraEntity.camera.fieldOfViewInDegrees = Float(OrbitCamera.verticalFOV * 180 / .pi)
        cameraAnchor.addChild(cameraEntity)
        view.scene.addAnchor(cameraAnchor)
        view.scene.addAnchor(modelAnchor)
        // Drive the turntable off RealityKit's own render loop — no Timer, and
        // it naturally pauses when the view isn't rendering.
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(deltaTime: event.deltaTime)
        }
    }

    func detach() {
        updateSubscription?.cancel()
        updateSubscription = nil
    }

    func update(mesh: ViewportMeshData?, identity: String?) {
        guard identity != currentIdentity else { return }
        currentIdentity = identity
        angle = 0
        elapsed = 0
        modelAnchor.children.removeAll()
        spinTarget = nil

        guard let mesh,
              let resource = resource(for: mesh, identity: identity),
              let bounds = ShapePreviewMath.bounds(of: mesh.positions) else { return }

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1))
        material.roughness = 0.55
        material.metallic = 0.0
        let entity = ModelEntity(mesh: resource, materials: [material])
        // Recentre so the shape spins about its own centroid, framed at origin.
        entity.position = -bounds.center
        let pivot = Entity()
        pivot.addChild(entity)
        modelAnchor.addChild(pivot)
        spinTarget = pivot

        frameCamera(radius: Double(bounds.radius))
    }

    private func resource(for mesh: ViewportMeshData, identity: String?) -> MeshResource? {
        if let identity, let cached = meshCache[identity] { return cached }
        let buffers = MeshFlattener.flatten(positions: mesh.positions, faceLoops: mesh.faceLoops)
        guard !buffers.triangleIndices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "shapePreview")
        descriptor.positions = MeshBuffer(buffers.positions)
        descriptor.normals = MeshBuffer(buffers.normals)
        descriptor.primitives = .triangles(buffers.triangleIndices)
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        if let identity { meshCache[identity] = resource }
        return resource
    }

    private func frameCamera(radius: Double) {
        var camera = OrbitCamera()
        camera.frame(center: .zero, radius: radius)
        camera.elevation = 0.35
        let pos = SIMD3<Float>(camera.position)
        cameraEntity.look(at: .zero, from: pos, relativeTo: nil)
    }

    /// Accumulated seconds of turntable motion, so the wrapped angle stays a
    /// pure function of elapsed time (matching `ShapePreviewMath.turntableAngle`).
    private var elapsed: Double = 0

    private func tick(deltaTime: TimeInterval) {
        guard let spinTarget, radiansPerSecond != 0 else { return }
        elapsed += deltaTime
        angle = ShapePreviewMath.turntableAngle(elapsed: elapsed, radiansPerSecond: radiansPerSecond)
        spinTarget.orientation = simd_quatf(angle: Float(angle), axis: SIMD3<Float>(0, 1, 0))
    }
}
// coverage:enable

#endif
