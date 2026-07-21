import Foundation
import EditingKit
import MeshKit
import SculptKit
import USDCore

/// Runs the SculptKit staged-sculpt pipeline **in-app against the open
/// document**, so each pass renders live in the viewport exactly like a
/// library insert — no file, no second process (specs/sculpt-pipeline.md).
///
/// `SculptKit` emits declarative `BuildStep`s; this runner maps each one to an
/// `EditorDocument` command (`InsertPrimCommand`, `SetTransformCommand`,
/// `CreateMaterialCommand`) and runs it through the document's `CommandStack`,
/// which drives the live-transform cache the viewport observes.
@MainActor
public enum SculptBuildRunner {

    /// Apply every `BuildStep` of one pass to the document. Returns the authored
    /// prim paths (best-effort — a failed step is skipped, not fatal, so a
    /// partial pass still shows in the viewport).
    @discardableResult
    public static func apply(pass: SculptPass, of spec: ObjectSculptSpec,
                             to document: EditorDocument) -> [String] {
        var authored: [String] = []
        for step in BuildPlanner.plan(for: spec, pass: pass) {
            if let path = apply(step: step, to: document) {
                authored.append(path)
            }
        }
        return authored
    }

    /// Play the whole pipeline pass-by-pass with a delay between passes so the
    /// build is watchable in the viewport. Review-only passes (which author
    /// nothing) are stepped through without pausing.
    public static func playLive(_ spec: ObjectSculptSpec, into document: EditorDocument,
                                passDelay: Duration = .milliseconds(650)) async {
        for pass in SculptPass.allCases {
            let authored = apply(pass: pass, of: spec, to: document)
            guard !authored.isEmpty else { continue }
            try? await Task.sleep(for: passDelay)
        }
    }

    // MARK: - Step → command

    static func apply(step: BuildStep, to document: EditorDocument) -> String? {
        switch step {
        case .createGroup(let name, let parentPath):
            return insert(prim: group(at: fullPath(name, under: parentPath)), to: document)

        case let .createMesh(name, parentPath, primitive, width, height, depth, radius, segments):
            guard let mesh = try? buildPrimitive(primitive, width: width, height: height,
                                                 depth: depth, radius: radius, segments: segments)
            else { return nil }
            return insert(prim: meshPrim(at: fullPath(name, under: parentPath), from: mesh), to: document)

        case .createLibraryMesh(let name, let parentPath, let entryID):
            guard let entry = ShapeLibrary.entry(id: entryID), let mesh = try? entry.build()
            else { return nil }
            return insert(prim: meshPrim(at: fullPath(name, under: parentPath), from: mesh), to: document)

        case let .setTransform(path, translation, rotation, scale):
            guard let primPath = PrimPath(path), document.snapshot.prim(at: primPath) != nil
            else { return nil }
            let trs = TRS(translation: translation, rotationEulerDegrees: rotation, scale: scale)
            let old = document.snapshot.prim(at: primPath)?.attribute(named: transformAttributeName)
            return document.run(SetTransformCommand(path: primPath, newTRS: trs, oldAttribute: old)) != nil
                ? primPath.description : nil

        case .createMaterial(let targetPath, let baseColor):
            guard let primPath = PrimPath(targetPath),
                  let command = CreateMaterialCommand.make(
                    bindingTo: primPath, baseColor: baseColor, in: document.snapshot)
            else { return nil }
            return document.run(command) != nil ? command.materialPath.description : nil

        case .authorRuntime(let rootPath, let manifestJSON):
            guard let primPath = PrimPath(rootPath), document.snapshot.prim(at: primPath) != nil
            else { return nil }
            let attribute = Attribute(name: "sculptRuntime", value: .string(manifestJSON))
            let old = document.snapshot.prim(at: primPath)?.attribute(named: "sculptRuntime")
            return document.run(SetAttributeCommand(path: primPath, newAttribute: attribute, oldAttribute: old)) != nil
                ? primPath.description : nil
        }
    }

    // MARK: - Prim construction (parent-aware; mirrors LibraryInsertion.makePrim)

    static func insert(prim: Prim?, to document: EditorDocument) -> String? {
        guard let prim else { return nil }
        let parent = prim.path.depth > 1 ? prim.path.parent : nil
        let siblings = parent.flatMap { document.snapshot.prim(at: $0)?.children }
            ?? document.snapshot.rootPrims
        // Skip if a sibling with this name already exists (idempotent re-runs).
        guard !siblings.contains(where: { $0.name == prim.path.name }) else { return nil }
        return document.run(InsertPrimCommand(prim: prim, parent: parent, index: siblings.count)) != nil
            ? prim.path.description : nil
    }

    static func fullPath(_ name: String, under parent: String?) -> String {
        (parent ?? "") + "/" + name
    }

    static func group(at path: String) -> Prim? {
        guard let primPath = PrimPath(path) else { return nil }
        return Prim(
            path: primPath, typeName: "Xform",
            attributes: [Attribute(name: transformAttributeName, value: .matrix4(Matrix4.identity))])
    }

    static func meshPrim(at path: String, from mesh: HalfEdgeMesh) -> Prim? {
        guard let xformPath = PrimPath(path), let meshPath = xformPath.appending("Geo") else { return nil }
        let flat = MeshIO.flat(from: mesh)
        var points: [Double] = []
        points.reserveCapacity(flat.points.count * 3)
        for p in flat.points { points += [p.x, p.y, p.z] }
        let geo = Prim(
            path: meshPath, typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .float3Array(points)),
                Attribute(name: "faceVertexCounts", value: .intArray(flat.faceVertexCounts)),
                Attribute(name: "faceVertexIndices", value: .intArray(flat.faceVertexIndices)),
                Attribute(name: "subdivisionScheme", value: .token("none"), isUniform: true),
            ])
        return Prim(
            path: xformPath, typeName: "Xform",
            attributes: [Attribute(name: transformAttributeName, value: .matrix4(Matrix4.identity))],
            children: [geo])
    }

    static func buildPrimitive(
        _ primitive: ShapeKind.Primitive,
        width: Double, height: Double, depth: Double, radius: Double, segments: Int
    ) throws -> HalfEdgeMesh {
        switch primitive {
        case .plane: return try Primitives.plane(width: width, depth: depth)
        case .box: return try Primitives.box(width: width, height: height, depth: depth)
        case .cylinder: return try Primitives.cylinder(radius: radius, height: height, radialSegments: segments)
        case .cone: return try Primitives.cone(radius: radius, height: height, radialSegments: segments)
        case .sphere: return try Primitives.uvSphere(radius: radius, rings: max(3, segments / 2), segments: segments)
        }
    }
}
