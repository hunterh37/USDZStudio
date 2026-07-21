#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
#if canImport(AppKit)
import AppKit
#endif

/// Applies `SceneGraphDiff` operations to a live RealityKit entity tree.
///
/// Split out of `ViewportCoordinator` so the entity-tree bookkeeping is
/// testable against a bare `Entity` root, with no `ARView` and no window — the
/// coordinator keeps only the wiring.
///
/// ## Two provenances, one tree
///
/// Entities come from two places and this type is careful about which is which:
///
/// - **Loader-backed** entities come from `Entity.load(contentsOf:)` and carry
///   the file's real materials, textures and skinning. The applier never
///   creates, destroys or re-meshes these — the existing prune / live-transform
///   / material-override channels own them, and clobbering their geometry would
///   throw away exactly the fidelity the fast path exists to preserve.
/// - **Synthesized** entities are built here from `ViewportMeshData` for prims
///   the file never contained: shapes added from the library, prims authored by
///   a script or an MCP agent. These the applier owns end to end.
///
/// The practical consequence is that a diff op is applied only when it targets
/// a prim this applier synthesized; ops for loader-backed prims are no-ops
/// here, because another channel already handles them.
@MainActor
final class SceneGraphApplier {

    /// The anchor synthesized root prims are parented under (the same anchor
    /// the loaded model hangs from, so both provenances share a coordinate
    /// space and one framing/bounds computation).
    private let root: Entity
    /// Locates a loader-backed entity for a prim path, so the applier can tell
    /// the two provenances apart and parent synthesized children correctly
    /// under loader-backed parents. Injected so tests need no real load.
    private let findLoaded: (String) -> Entity?

    /// Prim path → entity this applier created.
    private(set) var synthesized: [String: Entity] = [:]
    /// The scene the tree currently reflects; the left-hand side of the next diff.
    private(set) var appliedScene = ViewportScene()

    init(root: Entity, findLoaded: @escaping (String) -> Entity? = { _ in nil }) {
        self.root = root
        self.findLoaded = findLoaded
    }

    /// Diffs `scene` against what is currently drawn and applies the result.
    /// Cheap when nothing changed — an equal scene produces no operations.
    func apply(_ scene: ViewportScene) {
        guard scene != appliedScene else { return }
        let ops = SceneGraphDiff.operations(from: appliedScene, to: scene)
        appliedScene = scene
        for op in ops { apply(op) }
    }

    /// Adopts `scene` as the drawn state *without* emitting operations — used
    /// right after a file load, where the loader has already materialized every
    /// prim in the file. This is what makes the file a seed rather than the
    /// source of truth: it establishes the baseline the first real diff runs
    /// against.
    ///
    /// Prims in `scene` that the loader did *not* produce are synthesized, so a
    /// document edited while its file was still loading (or a scene with no
    /// file at all) still renders completely.
    func seed(with scene: ViewportScene) {
        synthesized.removeAll()
        appliedScene = scene
        for node in scene.nodes.values.sorted(by: { ($0.depth, $0.path) < ($1.depth, $1.path) })
        where findLoaded(node.path) == nil {
            insert(node)
        }
    }

    /// Drops all synthesized entities and forgets the drawn scene (model swap
    /// or document close). Loader-backed entities are the loader's to remove.
    func reset() {
        for entity in synthesized.values { entity.removeFromParent() }
        synthesized.removeAll()
        appliedScene = ViewportScene()
    }

    // MARK: Operation application

    private func apply(_ op: SceneGraphOperation) {
        switch op {
        case .insert(let node):
            // A prim the loader already drew needs no entity of ours.
            guard findLoaded(node.path) == nil else { return }
            insert(node)
        case .remove(let path):
            remove(path)
        case .updateMesh(let path, let mesh):
            updateMesh(path, to: mesh)
        case .updateVertices(let path, _):
            // The interactive vertex drag never routes through here — it writes
            // the edit entity's `LowLevelMesh` directly via `LiveMeshRenderer`
            // for a true partial GPU update (specs/viewport.md). This case serves
            // the programmatic / MCP / undo-redo path, which is not per-frame.
            // Synthesized entities are flat-shaded (per-face duplicated vertices),
            // so there is no 1:1 buffer slot for a prim vertex index; rebuild from
            // the already-updated scene node, which is correct and cheap here.
            updateMesh(path, to: appliedScene[path]?.mesh)
        case .updateTransform(let path, let transform):
            synthesized[path]?.transform = Transform(matrix: transform)
        case .setEnabled(let path, let isEnabled):
            synthesized[path]?.isEnabled = isEnabled
        }
    }

    private func insert(_ node: ViewportPrimNode) {
        let entity = Self.makeEntity(for: node)
        entity.name = Self.name(of: node.path)
        entity.transform = Transform(matrix: node.transform)
        entity.isEnabled = node.isEnabled
        parent(of: node).addChild(entity)
        synthesized[node.path] = entity
    }

    /// Removes `path`'s entity and forgets every synthesized descendant along
    /// with it — RealityKit detaches the subtree in one call, but the index
    /// would otherwise keep dangling entries that later ops would write to.
    private func remove(_ path: String) {
        synthesized[path]?.removeFromParent()
        let prefix = path + "/"
        for key in synthesized.keys where key == path || key.hasPrefix(prefix) {
            synthesized.removeValue(forKey: key)
        }
    }

    /// Swaps geometry on a synthesized entity in place, preserving its
    /// transform, enablement and children — a re-mesh must not detach the
    /// subtree hanging off it.
    private func updateMesh(_ path: String, to mesh: ViewportMeshData?) {
        guard let existing = synthesized[path], let node = appliedScene[path] else { return }
        let replacement = Self.makeEntity(for: ViewportPrimNode(path: path, mesh: mesh))
        replacement.name = existing.name
        replacement.transform = existing.transform
        replacement.isEnabled = node.isEnabled
        for child in existing.children.map({ $0 }) {
            replacement.addChild(child)
        }
        let parent = existing.parent ?? self.parent(of: node)
        existing.removeFromParent()
        parent.addChild(replacement)
        synthesized[path] = replacement
    }

    /// The entity a node should hang from: its parent prim's entity from either
    /// provenance, falling back to the root when the parent isn't drawn (a root
    /// prim, or a parent the stage doesn't describe).
    private func parent(of node: ViewportPrimNode) -> Entity {
        guard let parentPath = node.parentPath else { return root }
        return synthesized[parentPath] ?? findLoaded(parentPath) ?? root
    }

    /// A `ModelEntity` when the node carries geometry, otherwise a plain
    /// `Entity` — grouping prims still need a node so children inherit their
    /// transform, but they must not render.
    private static func makeEntity(for node: ViewportPrimNode) -> Entity {
        guard let mesh = node.mesh,
              let resource = meshResource(for: mesh) else { return Entity() }
        return ModelEntity(mesh: resource, materials: [defaultMaterial()])
    }

    /// Flat-shaded triangle buffers → `MeshResource`. `nil` when the geometry
    /// has no drawable triangles, which falls back to a group entity rather
    /// than failing the insert.
    private static func meshResource(for mesh: ViewportMeshData) -> MeshResource? {
        let buffers = MeshFlattener.flatten(positions: mesh.positions, faceLoops: mesh.faceLoops)
        guard !buffers.triangleIndices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "synthesizedMesh")
        descriptor.positions = MeshBuffer(buffers.positions)
        descriptor.normals = MeshBuffer(buffers.normals)
        descriptor.primitives = .triangles(buffers.triangleIndices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Neutral PBR stand-in for prims with no file material to inherit. The
    /// document's `MaterialOverride` channel repaints this the moment the user
    /// authors a material opinion.
    private static func defaultMaterial() -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(srgbRed: 0.72, green: 0.73, blue: 0.76, alpha: 1))
        material.roughness = .init(floatLiteral: 0.55)
        material.metallic = .init(floatLiteral: 0)
        return material
    }

    /// The last path segment — how RealityKit names the entity, keeping
    /// synthesized entities discoverable by the same `findEntity(primPath:)`
    /// lookup loader-backed ones use.
    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
#endif
