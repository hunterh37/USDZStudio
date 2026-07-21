#if canImport(RealityKit)
import Foundation
import RealityKit
import simd

/// Owns the GPU-resident geometry for the prim under live vertex editing and
/// applies drag previews as **partial** vertex-buffer writes rather than whole
/// `MeshResource` rebuilds (specs/viewport.md — "entity diff rebuild < 16ms for
/// single-prim edits"). Backed by `LowLevelMesh` (macOS 15+), whose vertex
/// buffer we mutate in place via `withUnsafeMutableBytes`; the index buffer is
/// written once at session start because topology is fixed under a drag.
///
/// All CPU-side arithmetic lives in the pure, unit-tested `LiveMeshBuffers`; the
/// code here is the thin RealityKit submission glue.
///
/// > De-risk dependency: the partial-write fast path assumes a `MeshResource`
/// > built from a `LowLevelMesh` reflects in-place buffer writes without a
/// > resource swap. That assumption is validated by the spike in ROADMAP
/// > (Phase 8 gate) before this path is trusted in production; until then the
/// > coordinator may fall back to `updateMesh`.
@MainActor
final class LiveMeshRenderer {

    /// Vertex layout mirrored into the `LowLevelMesh`: position + normal, both
    /// `packed_float3`-adjacent. Kept in one struct so the stride math is local.
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    private(set) var buffers: LiveMeshBuffers?
    private var lowLevelMesh: LowLevelMesh?
    private(set) var entity: ModelEntity?

    /// Build the persistent buffers + entity for an edit session. Returns the
    /// entity to parent under the edit anchor, or `nil` if the geometry has no
    /// drawable triangles.
    // coverage:disable — GPU submission glue (LowLevelMesh allocation); the
    // buffer arithmetic it feeds on is covered via LiveMeshBuffers tests, and
    // the rendered result is covered by golden-image tests, per specs/testing.md.
    @discardableResult
    func begin(_ data: EditedMeshData) -> ModelEntity? {
        let buffers = LiveMeshBuffers(positions: data.positions, faceLoops: data.faceLoops)
        guard !buffers.triangleIndices.isEmpty else {
            self.buffers = nil
            return nil
        }
        self.buffers = buffers
        guard let mesh = try? makeLowLevelMesh(buffers) else { return nil }
        self.lowLevelMesh = mesh
        writeBuffers(buffers, into: mesh)
        guard let resource = try? MeshResource(from: mesh) else { return nil }
        let entity = ModelEntity(mesh: resource, materials: [Self.editMaterial()])
        self.entity = entity
        return entity
    }

    /// Apply a drag preview: absolute new positions for a subset of vertices.
    /// Rewrites only the changed slots and their affected normals — no MeshKit,
    /// no session mutation, no `MeshResource` regeneration.
    func previewVertices(_ changes: [Int: SIMD3<Float>]) {
        guard var buffers, let mesh = lowLevelMesh, !changes.isEmpty else { return }
        buffers.applyPositionChanges(changes)
        self.buffers = buffers
        writeBuffers(buffers, into: mesh)
    }

    /// Tear down the session's GPU resources.
    func end() {
        entity?.removeFromParent()
        entity = nil
        lowLevelMesh = nil
        buffers = nil
    }

    private func makeLowLevelMesh(_ buffers: LiveMeshBuffers) throws -> LowLevelMesh {
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<SIMD3<Float>>.stride),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride),
        ]
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = buffers.positions.count
        descriptor.indexCapacity = buffers.triangleIndices.count
        descriptor.vertexAttributes = attributes
        descriptor.vertexLayouts = layouts
        descriptor.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: descriptor)

        // Index buffer is written once — topology is fixed for the session.
        mesh.withUnsafeMutableIndices { raw in
            raw.withMemoryRebound(to: UInt32.self) { dst in
                for i in buffers.triangleIndices.indices { dst[i] = buffers.triangleIndices[i] }
            }
        }
        return mesh
    }

    /// Mirror positions + normals into the LowLevelMesh vertex buffer and update
    /// the part's bounds. Writing the whole vertex buffer here keeps the glue
    /// simple; the *savings* come from `applyPositionChanges` touching only the
    /// affected CPU slots, and from never regenerating the `MeshResource`.
    private func writeBuffers(_ buffers: LiveMeshBuffers, into mesh: LowLevelMesh) {
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let dst = raw.bindMemory(to: Vertex.self)
            for i in buffers.positions.indices {
                dst[i] = Vertex(position: buffers.positions[i], normal: buffers.normals[i])
            }
        }
        var lower = SIMD3<Float>(repeating: .infinity)
        var upper = SIMD3<Float>(repeating: -.infinity)
        for p in buffers.positions {
            lower = simd_min(lower, p); upper = simd_max(upper, p)
        }
        let bounds = BoundingBox(min: lower, max: upper)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0,
                              indexCount: buffers.triangleIndices.count,
                              topology: .triangle,
                              materialIndex: 0,
                              bounds: bounds)
        ])
    }

    private static func editMaterial() -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(red: 0.72, green: 0.73, blue: 0.76, alpha: 1))
        material.roughness = .init(floatLiteral: 0.55)
        material.metallic = .init(floatLiteral: 0)
        return material
    }
    // coverage:enable
}
#endif
