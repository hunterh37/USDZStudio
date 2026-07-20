import Foundation
import USDCore
import EditingKit
import MeshKit

/// Turns a `ShapeLibrary` entry into a scene prim and inserts it into the open
/// document as an undoable command. Mirrors `TutorialScene.makeCubePrim`: an
/// `Xform` carrying the transform, wrapping a `Mesh` child so transforms and
/// geometry live on separate prims (matching real imported assets).
enum LibraryInsertion {

    /// Builds `entry`'s mesh, wraps it in an Xform+Mesh prim with a unique root
    /// name, and inserts it at the end of the root prims. Returns an error
    /// message on failure, `nil` on success.
    @discardableResult
    @MainActor
    static func insert(_ entry: ShapeEntry, into document: EditorDocument) -> String? {
        let mesh: HalfEdgeMesh
        do {
            mesh = try entry.build()
        } catch {
            return "Couldn’t build \(entry.name): \(error)"
        }
        let name = uniqueRootName(base: entry.name, in: document)
        guard let prim = makePrim(named: name, from: mesh) else {
            return "Couldn’t create a prim named \(name)."
        }
        return document.run(InsertPrimCommand(
            prim: prim, parent: nil, index: document.snapshot.rootPrims.count))
    }

    /// Xform (identity transform) wrapping a Mesh child built from `mesh`.
    static func makePrim(named name: String, from mesh: HalfEdgeMesh) -> Prim? {
        guard let xformPath = PrimPath("/\(name)"),
              let meshPath = xformPath.appending("Geo") else { return nil }

        let flat = MeshIO.flat(from: mesh)
        var points: [Double] = []
        points.reserveCapacity(flat.points.count * 3)
        for p in flat.points { points += [p.x, p.y, p.z] }

        let geo = Prim(
            path: meshPath,
            typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .float3Array(points)),
                Attribute(name: "faceVertexCounts", value: .intArray(flat.faceVertexCounts)),
                Attribute(name: "faceVertexIndices", value: .intArray(flat.faceVertexIndices)),
                // Without this USD defaults to catmullClark and low-poly stock
                // renders as a subdivided blob.
                Attribute(name: "subdivisionScheme", value: .token("none"), isUniform: true),
            ])

        return Prim(
            path: xformPath,
            typeName: "Xform",
            attributes: [
                Attribute(name: "xformOp:transform", value: .matrix4(Matrix4.identity)),
            ],
            children: [geo])
    }

    /// A valid prim name derived from `base`, made unique among existing root
    /// prim names by suffixing `_1`, `_2`, …
    @MainActor
    static func uniqueRootName(base: String, in document: EditorDocument) -> String {
        let clean = PrimPath.isValidName(base) ? base : PrimPath.sanitizedName(from: base)
        let existing = Set(document.snapshot.rootPrims.map(\.name))
        guard existing.contains(clean) else { return clean }
        var i = 1
        while existing.contains("\(clean)_\(i)") { i += 1 }
        return "\(clean)_\(i)"
    }
}
