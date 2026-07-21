import Testing
import Foundation
import simd
import USDCore
import MeshKit
import EditingKit
import ViewportKit
@testable import EditorUI

/// The performance contract behind issue #1's object-drag half: a transform-only
/// gizmo drag republishes the stage snapshot every pointer event, but it must
/// *not* invalidate the viewport's per-prim geometry cache — otherwise every
/// event re-walks every mesh's points. These tests pin that behaviour to the
/// `geometryRevision` counter and the `meshCache` generation stamp so a
/// regression (e.g. a transform handler slipping back to the geometry-bumping
/// `refresh()`) fails the suite rather than silently costing frames.
@MainActor
@Suite("Geometry revision & viewport mesh cache")
struct GeometryRevisionCacheTests {

    private func meshPrim(_ path: String) -> Prim {
        Prim(path: PrimPath(path)!, typeName: "Mesh",
             attributes: [
                Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0])),
                Attribute(name: "faceVertexCounts", value: .intArray([3])),
                Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2])),
             ])
    }

    private func selectedMeshDoc(_ path: String = "/M") -> (EditorDocument, PrimPath) {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim(path)]))
        doc.selection = Selection([PrimPath(path)!])
        return (doc, PrimPath(path)!)
    }

    private func cube() -> ShapeEntry { ShapeLibrary.entry(id: "prim.cube")! }

    // MARK: geometryRevision movement

    @Test("A translate drag preview bumps revision but not geometryRevision")
    func translatePreviewKeepsGeometryRevision() {
        let (doc, _) = selectedMeshDoc()
        let rev0 = doc.revision
        let geo0 = doc.geometryRevision
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 1.0))
        doc.handleTranslateGizmoDrag(.changed(.x, 2.0))
        #expect(doc.revision > rev0)                 // the viewport still refreshes
        #expect(doc.geometryRevision == geo0)        // …but geometry is untouched
        doc.handleTranslateGizmoDrag(.ended)
    }

    @Test("Rotate and scale drag previews also leave geometryRevision alone")
    func rotateScalePreviewsKeepGeometryRevision() {
        let (doc, _) = selectedMeshDoc()
        let geo0 = doc.geometryRevision

        doc.handleRotateGizmoDrag(.began(.y))
        doc.handleRotateGizmoDrag(.changed(.y, 15))
        doc.handleRotateGizmoDrag(.ended)

        doc.handleScaleGizmoDrag(.began(.uniform))
        doc.handleScaleGizmoDrag(.changed(.uniform, 1.5))
        doc.handleScaleGizmoDrag(.changed(.axis(.x), 2.0))
        doc.handleScaleGizmoDrag(.ended)

        // Each `.changed` preview left geometry untouched. The two committed
        // gestures (`.ended` → run) each bump geometryRevision once — a per-
        // gesture cost, not the per-event cost the fix targets.
        #expect(doc.geometryRevision == geo0 + 2)
    }

    @Test("A geometry-changing command bumps geometryRevision")
    func insertBumpsGeometryRevision() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let geo0 = doc.geometryRevision
        LibraryInsertion.insert(cube(), into: doc)
        #expect(doc.geometryRevision > geo0)
    }

    // MARK: mesh cache reuse vs invalidation

    @Test("A transform drag reuses the cached geometry (sentinel survives)")
    func transformDragReusesMeshCache() {
        let (doc, _) = selectedMeshDoc()
        _ = doc.viewportScene                 // populate the cache
        #expect(doc.meshCacheGeneration == doc.geometryRevision)
        // A marker that only real geometry re-extraction (a cache clear) removes.
        doc.meshCache.updateValue(nil, forKey: "/__sentinel__")

        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 3.0))
        _ = doc.viewportScene                 // recompute scene at the new transform
        doc.handleTranslateGizmoDrag(.ended)

        // The scene recomputed (transform moved) yet the geometry cache was NOT
        // cleared — the extraction was served from cache.
        #expect(doc.meshCache.index(forKey: "/__sentinel__") != nil)
    }

    @Test("A geometry edit clears the mesh cache (sentinel removed)")
    func geometryEditClearsMeshCache() {
        let (doc, _) = selectedMeshDoc()
        _ = doc.viewportScene
        doc.meshCache.updateValue(nil, forKey: "/__sentinel__")

        LibraryInsertion.insert(cube(), into: doc)
        _ = doc.viewportScene                 // recompute after a real geometry change

        #expect(doc.meshCache.index(forKey: "/__sentinel__") == nil)
    }

    // MARK: correctness is preserved by the cache

    @Test("Cache reuse still yields the moved transform and intact geometry")
    func cacheReuseKeepsCorrectness() {
        let (doc, path) = selectedMeshDoc()
        _ = doc.viewportScene
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 4.0))
        doc.handleTranslateGizmoDrag(.ended)

        let node = doc.viewportScene[path.description]
        // Geometry is intact (served from cache)…
        #expect(node?.mesh?.faceLoops == [[0, 1, 2]])
        // …and the transform reflects the completed move.
        #expect(node?.transform.columns.3.x == 4.0)
    }
}
