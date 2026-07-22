import Foundation
import USDCore
import MeshKit

/// One committed mesh-edit session flushed to the stage as a single undoable
/// command (specs/mesh-editing.md §Undo & commands).
///
/// The edit-mode session holds the working `HalfEdgeMesh` in memory; on commit
/// the mesh is exported to USD flat arrays and authored via `points` /
/// `faceVertexCounts` / `faceVertexIndices` (+ face-varying UVs when carried).
/// Undo restores the prior arrays byte-for-byte.
public struct MeshEditCommand: EditCommand {
    public let path: PrimPath
    public let before: FlatMesh
    public let after: FlatMesh
    /// Human label for Edit ▸ Undo, e.g. "Extrude", "Fill Hole".
    public let opLabel: String

    public init(path: PrimPath, before: FlatMesh, after: FlatMesh, opLabel: String) {
        self.path = path
        self.before = before
        self.after = after
        self.opLabel = opLabel
    }

    public var label: String { "\(opLabel) (\(path.name))" }

    public func execute(on stage: any USDStageMutable) throws {
        try write(after, on: stage)
    }

    public func undo(on stage: any USDStageMutable) throws {
        try write(before, on: stage)
    }

    private func write(_ mesh: FlatMesh, on stage: any USDStageMutable) throws {
        var points: [Double] = []
        points.reserveCapacity(mesh.points.count * 3)
        for p in mesh.points { points += [p.x, p.y, p.z] }

        try stage.apply(.setAttribute(path: path, attribute:
            Attribute(name: "points", value: .float3Array(points))))
        try stage.apply(.setAttribute(path: path, attribute:
            Attribute(name: "faceVertexCounts", value: .intArray(mesh.faceVertexCounts))))
        try stage.apply(.setAttribute(path: path, attribute:
            Attribute(name: "faceVertexIndices", value: .intArray(mesh.faceVertexIndices))))
        // Re-author normals for the edited topology so the mesh keeps shading
        // smoothly instead of pointing at the pre-edit surface, and so an edit
        // never re-introduces a `mesh.normals` diagnostic (issue #95). The math
        // lives once in `MeshKit.VertexNormals`.
        let normals = VertexNormals.smoothFlat(for: mesh)
        if !normals.isEmpty {
            try stage.apply(.setAttribute(path: path, attribute:
                Attribute(name: "normals", value: .float3Array(normals),
                          metadata: ["interpolation": "\"vertex\""])))
        }
        if !mesh.faceVaryingUVs.isEmpty {
            var uvs: [Double] = []
            uvs.reserveCapacity(mesh.faceVaryingUVs.count * 2)
            for uv in mesh.faceVaryingUVs { uvs += [uv.x, uv.y] }
            try stage.apply(.setAttribute(path: path, attribute:
                Attribute(name: "primvars:st", value: .doubleArray(uvs),
                          metadata: ["interpolation": "faceVarying"])))
        }
    }
}

/// In-memory edit-mode session for one mesh prim. Applies MeshKit ops to a
/// working copy, keeps CoW snapshots for in-session undo, and produces a
/// `MeshEditCommand` on commit. Crash journal: the op list is recorded so a
/// crashed session can be replayed.
public struct MeshEditSession: Sendable {
    public let path: PrimPath
    public let original: FlatMesh
    public private(set) var mesh: HalfEdgeMesh
    private var undoStack: [HalfEdgeMesh] = []
    /// Human-readable op journal ("Extrude d=0.5", …) for crash recovery.
    public private(set) var journal: [String] = []

    /// Refuses skinned meshes with the explicit diagnostic (spec §Skinned).
    public init(path: PrimPath, flat: FlatMesh) throws {
        self.path = path
        self.original = flat
        self.mesh = try MeshIO.mesh(from: flat) // throws .skinnedMeshUnsupported
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var isDirty: Bool { !journal.isEmpty }

    /// Apply an op result produced by a MeshKit op against `mesh`.
    public mutating func record(_ result: MeshOpResult, journalEntry: String) {
        undoStack.append(mesh)
        mesh = result.mesh
        journal.append(journalEntry)
    }

    public mutating func undo() {
        guard let prior = undoStack.popLast() else { return }
        mesh = prior
        journal.removeLast()
    }

    /// Flush the session to a single stage command; nil when nothing changed.
    public func commitCommand() -> MeshEditCommand? {
        guard isDirty else { return nil }
        return MeshEditCommand(path: path, before: original,
                               after: MeshIO.flat(from: mesh),
                               opLabel: journal.count == 1 ? journal[0] : "Mesh Edit (\(journal.count) ops)")
    }
}
