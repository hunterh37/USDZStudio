import Foundation
import USDCore
import EditingKit
import MeshKit

/// Builds the guided tour's sandbox document: a unit cube (Xform + Mesh, so
/// transforms and mesh edits live on separate prims, matching real imported
/// assets) serialized to a temp `.usda` the viewport can load. The tour edits
/// this scratch document, never the user's files.
enum TutorialScene {

    static let cubePath = PrimPath("/TutorialCube")!
    static let meshPath = PrimPath("/TutorialCube/Geo")!

    /// The cube prim tree (captured so the "Create" step can re-insert it
    /// after the intro deletes it).
    static func makeCubePrim() throws -> Prim {
        let flat = MeshIO.flat(from: try Primitives.box())
        var points: [Double] = []
        points.reserveCapacity(flat.points.count * 3)
        for p in flat.points { points += [p.x, p.y, p.z] }

        var attributes: [Attribute] = [
            Attribute(name: "points", value: .float3Array(points)),
            Attribute(name: "faceVertexCounts", value: .intArray(flat.faceVertexCounts)),
            Attribute(name: "faceVertexIndices", value: .intArray(flat.faceVertexIndices)),
            // Without this USD defaults to catmullClark and the cube
            // renders as a subdivided blob.
            Attribute(name: "subdivisionScheme", value: .token("none"), isUniform: true),
        ]
        // Real normals so the tour's scratch cube shades like an imported asset
        // and the sandbox stage carries no `mesh.normals` diagnostic (issue #95).
        let normals = VertexNormals.smoothFlat(for: flat)
        if !normals.isEmpty {
            attributes.append(Attribute(
                name: "normals", value: .float3Array(normals),
                metadata: ["interpolation": "\"vertex\""]))
        }
        let mesh = Prim(path: meshPath, typeName: "Mesh", attributes: attributes)

        return Prim(
            path: cubePath,
            typeName: "Xform",
            attributes: [
                Attribute(name: "xformOp:transform", value: .matrix4(Matrix4.identity)),
            ],
            children: [mesh])
    }

    /// Serializes the scene and writes it to a temp `.usda`, returning the
    /// snapshot + file URL the tour document is built from.
    static func makeStage() throws -> (snapshot: StageSnapshot, url: URL) {
        let snapshot = StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1, defaultPrim: cubePath.name),
            rootPrims: [try makeCubePrim()])
        let text = USDASerializer.serialize(snapshot)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicyaninTutorial-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathExtension("usda")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (snapshot, url)
    }
}
