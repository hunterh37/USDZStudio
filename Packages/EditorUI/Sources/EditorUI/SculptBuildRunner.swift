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

        case .createMaterial(let targetPath, let material):
            guard let primPath = PrimPath(targetPath),
                  let command = CreateMaterialCommand.make(
                    bindingTo: primPath, baseColor: material.baseColor, in: document.snapshot)
            else { return nil }
            guard document.run(command) != nil else { return nil }
            // Author the remaining PBR channels (scalars + texture maps) onto
            // the surface shader; best-effort, mirroring the MCP executor.
            for attribute in materialChannelAttributes(material) {
                authorAttribute(attribute, on: command.surfacePath, to: document)
            }
            return command.materialPath.description

        case let .createLight(name, parentPath, kind, intensity, color):
            return insert(prim: lightPrim(at: fullPath(name, under: parentPath), kind: kind,
                                          intensity: intensity, color: color), to: document)

        case .projectTexture(let rootPath, let descriptorJSON):
            return authorRootAttribute(name: "sculptProjectedTexture", value: descriptorJSON,
                                       rootPath: rootPath, to: document)

        case .authorLOD(let rootPath, let manifestJSON):
            return authorRootAttribute(name: "sculptLOD", value: manifestJSON,
                                       rootPath: rootPath, to: document)

        case .authorRuntime(let rootPath, let manifestJSON):
            return authorRootAttribute(name: "sculptRuntime", value: manifestJSON,
                                       rootPath: rootPath, to: document)
        }
    }

    /// Build a typed `UsdLux` light prim with intensity/colour channels and an
    /// identity transform (the lighting pass positions it via `setTransform`).
    static func lightPrim(at path: String, kind: LightSpec.Kind,
                          intensity: Double, color: [Double]) -> Prim? {
        guard let primPath = PrimPath(path) else { return nil }
        return Prim(
            path: primPath, typeName: kind.usdTypeName,
            attributes: [
                Attribute(name: transformAttributeName, value: .matrix4(Matrix4.identity)),
                Attribute(name: "inputs:intensity", value: .double(intensity)),
                Attribute(name: "inputs:color", value: .vector(color)),
            ])
    }

    /// The extra shader-input attributes beyond the base colour authored by
    /// `CreateMaterialCommand`: roughness/metallic scalars, optional emissive,
    /// texture-map asset paths, and normal scale.
    static func materialChannelAttributes(_ material: MaterialSpec) -> [Attribute] {
        var attributes: [Attribute] = [
            Attribute(name: "inputs:roughness", value: .double(material.roughness)),
            Attribute(name: "inputs:metallic", value: .double(material.metallic)),
        ]
        if let emissive = material.emissive {
            attributes.append(Attribute(name: "inputs:emissiveColor", value: .vector(emissive)))
        }
        let maps: [(String?, String)] = [
            (material.albedoMap, "inputs:albedoMap"), (material.normalMap, "inputs:normalMap"),
            (material.roughnessMap, "inputs:roughnessMap"), (material.emissiveMap, "inputs:emissiveMap"),
        ]
        for (path, name) in maps {
            if let path { attributes.append(Attribute(name: name, value: .string(path))) }
        }
        if let scale = material.normalScale {
            attributes.append(Attribute(name: "inputs:normalScale", value: .double(scale)))
        }
        return attributes
    }

    /// Set one attribute on an existing prim through the document command stack
    /// (best-effort; a missing prim or failed run is skipped).
    @discardableResult
    static func authorAttribute(_ attribute: Attribute, on path: PrimPath,
                                to document: EditorDocument) -> String? {
        guard document.snapshot.prim(at: path) != nil else { return nil }
        let old = document.snapshot.prim(at: path)?.attribute(named: attribute.name)
        return document.run(SetAttributeCommand(path: path, newAttribute: attribute, oldAttribute: old)) != nil
            ? path.description : nil
    }

    /// Author a string attribute onto the resolved sculpt-root prim (shared by
    /// the runtime-manifest and projected-texture descriptor steps).
    static func authorRootAttribute(name: String, value: String, rootPath: String,
                                    to document: EditorDocument) -> String? {
        guard let primPath = PrimPath(rootPath) else { return nil }
        return authorAttribute(Attribute(name: name, value: .string(value)), on: primPath, to: document)
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
