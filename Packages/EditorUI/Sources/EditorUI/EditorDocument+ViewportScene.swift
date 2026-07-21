import USDCore
import ViewportKit
import simd

/// Projects the live stage into the viewport's renderable scene description.
///
/// This is the seam that demotes the opened file from *source of truth* to
/// *initial seed*: the viewport diffs successive `viewportScene` values and
/// applies the difference to its entity tree, so prims that never existed in
/// the file (a shape added from the library, a scripted prim, an MCP-authored
/// prim) render exactly like prims that did.
extension EditorDocument {

    /// Every prim the viewport should be drawing, keyed by path. Cached per
    /// `revision` so repeated SwiftUI reads don't re-walk the stage.
    ///
    /// Enablement is taken from `viewportLivePrimPaths` rather than recomputed,
    /// so structural deletes, hide/deactivate, and isolate keep expressing
    /// themselves through exactly one rule.
    public var viewportScene: ViewportScene {
        let rev = viewportSceneRevision  // tracked read → views refresh on edits
        if sceneCacheRevision != rev {
            sceneCache = computeViewportScene()
            sceneCacheRevision = rev
        }
        return sceneCache
    }

    private func computeViewportScene() -> ViewportScene {
        let live = viewportLivePrimPaths
        let transforms = viewportLiveTransforms
        // Drop the memoized geometry only when an edit could actually have
        // changed it; a transform-only drag leaves this generation untouched, so
        // every `cachedMesh(for:)` below is a hit.
        if meshCacheGeneration != geometryRevision {
            meshCache.removeAll(keepingCapacity: true)
            meshCacheGeneration = geometryRevision
        }
        var nodes: [String: ViewportPrimNode] = [:]
        // Own-opinion visibility, before inheritance is resolved below.
        var selfVisible: [String: Bool] = [:]
        for prim in snapshot.allPrims() {
            let path = prim.path.description
            selfVisible[path] = prim.visibility != .invisible
            nodes[path] = ViewportPrimNode(
                path: path,
                transform: transforms[path] ?? matrix_identity_float4x4,
                mesh: cachedMesh(for: prim, path: path),
                isEnabled: live.contains(path))
        }

        // USD `visibility` is inherited: an invisible prim hides its whole
        // subtree, whatever the descendants themselves say. Resolving
        // shallowest-first lets each node read its parent's already-resolved
        // answer instead of re-walking the ancestor chain.
        for path in nodes.values.sorted(by: { ($0.depth, $0.path) < ($1.depth, $1.path) }).map(\.path) {
            guard var node = nodes[path] else { continue }
            let inherited = node.parentPath.flatMap { nodes[$0]?.isEnabled } ?? true
            node.isEnabled = node.isEnabled && (selfVisible[path] ?? true) && inherited
            nodes[path] = node
        }
        return ViewportScene(nodes: nodes)
    }

    /// `Self.mesh(from:)` for `prim`, served from `meshCache` when this prim's
    /// geometry was already extracted at the current `geometryRevision`. The
    /// cache is generation-cleared in `computeViewportScene`, so a stale entry
    /// can never outlive a geometry edit. `nil` results are cached too (via an
    /// explicit key check) so meshless prims aren't re-walked every event.
    private func cachedMesh(for prim: Prim, path: String) -> ViewportMeshData? {
        if let existing = meshCache.index(forKey: path) {
            return meshCache[existing].value
        }
        let mesh = Self.mesh(from: prim)
        meshCache[path] = mesh
        return mesh
    }

    /// Renderable geometry for `prim`, or `nil` when it carries none (a grouping
    /// Xform/Scope, or a Mesh whose point/topology attributes are missing or
    /// inconsistent — a malformed mesh renders as nothing rather than crashing
    /// the viewport).
    static func mesh(from prim: Prim) -> ViewportMeshData? {
        guard prim.typeName == "Mesh",
              case let .float3Array(flat)? = prim.attribute(named: "points")?.value,
              case let .intArray(counts)? = prim.attribute(named: "faceVertexCounts")?.value,
              case let .intArray(indices)? = prim.attribute(named: "faceVertexIndices")?.value,
              flat.count % 3 == 0
        else { return nil }

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(flat.count / 3)
        for i in stride(from: 0, to: flat.count, by: 3) {
            positions.append(SIMD3(Float(flat[i]), Float(flat[i + 1]), Float(flat[i + 2])))
        }

        // Walk the flattened index run one face at a time. Any count that
        // overruns the index array means the topology disagrees with itself, so
        // the whole mesh is rejected rather than partly drawn.
        var faceLoops: [[Int]] = []
        faceLoops.reserveCapacity(counts.count)
        var cursor = 0
        for count in counts {
            guard count >= 3, cursor + count <= indices.count else { return nil }
            let loop = Array(indices[cursor..<(cursor + count)])
            guard loop.allSatisfy(positions.indices.contains) else { return nil }
            faceLoops.append(loop)
            cursor += count
        }
        guard !faceLoops.isEmpty else { return nil }

        return ViewportMeshData(positions: positions, faceLoops: faceLoops)
    }
}
