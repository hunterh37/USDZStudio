import Foundation
import simd
import USDCore
import MeshKit

/// Stage 8 of the standard sequence: IntermediateScene → USD stage
/// (specs/conversion-pipeline.md). Authors a value-typed `StageSnapshot`;
/// USDBridge serializes it to usdz in the `package` stage.
///
/// For skinned/animated input it authors UsdSkel: a `SkelRoot` wrapping one
/// `Skeleton` per skin, a `SkelAnimation` sampled onto a shared timeline, and
/// `primvars:skel:*` binding on the skinned meshes. Non-skinned nodes that are
/// animated get decomposed, time-sampled `xformOp` translate/orient/scale.
public struct USDAuthorStage: ConversionStage {
    public let id = "usd-author"

    /// Default playback rate when the source declares none.
    public static let defaultFPS: Double = 24

    public init() {}

    public enum AuthorError: Error, Equatable {
        case illegalName(String)
        case danglingMeshIndex(node: String, index: Int)
    }

    public func process(_ context: inout ConversionContext) async throws {
        let scene = context.scene
        let rootName = USDNameSanitizer.isLegal(scene.name) ? scene.name : "Root"
        let rootPath = PrimPath("/\(rootName)")!  // rootName is legal by construction

        var plan = AuthorPlan(scene: scene, rootPath: rootPath)
        if scene.animations.count > 1 {
            context.diagnostics.append(Diagnostic(
                severity: .warning, stage: id,
                message: "\(scene.animations.count) animation clips; only \"\(scene.animations[0].name)\" is authored"))
        }

        var root = Prim(path: rootPath, typeName: plan.isSkinned ? "SkelRoot" : "Xform")
        root.children = try scene.rootNodes.map { try author($0, under: rootPath, plan: &plan) }

        // One Skeleton (+ optional SkelAnimation) per skin, under the SkelRoot.
        for skeleton in plan.skeletonPrims() {
            root.children.append(skeleton)
        }

        // Materials live under /<Root>/Materials, referenced by mesh index.
        if !scene.materials.isEmpty {
            let materialsPath = rootPath.appending("Materials")!  // literal legal name
            var materialsScope = Prim(path: materialsPath, typeName: "Scope")
            materialsScope.children = try scene.materials.map { try author($0, under: materialsPath) }
            root.children.append(materialsScope)
        }

        context.diagnostics.append(contentsOf: plan.diagnostics)
        context.authoredStage = StageSnapshot(
            sourceURL: context.sourceURL,
            metadata: StageMetadata(
                upAxis: .y, metersPerUnit: 1.0, defaultPrim: rootName,
                timeCodesPerSecond: plan.timeCodesPerSecond,
                startTimeCode: plan.startTimeCode,
                endTimeCode: plan.endTimeCode),
            rootPrims: [root])
    }

    // MARK: - Nodes

    private func author(_ node: SceneNode, under parent: PrimPath, plan: inout AuthorPlan) throws -> Prim {
        guard USDNameSanitizer.isLegal(node.name), let path = parent.appending(node.name) else {
            throw AuthorError.illegalName(node.name)
        }
        var prim = Prim(path: path, typeName: "Xform")

        // A non-joint node with transform channels gets decomposed, time-sampled
        // xformOps; everything else keeps the single static transform matrix.
        if let animated = plan.nodeTransformOps(for: node) {
            prim.attributes = animated
        } else {
            prim.attributes = [Attribute(name: "xformOp:transform", value: .matrix4(Self.rowMajor(node.transform)))]
        }

        let skeletonPath = node.skinIndex.flatMap { plan.skeletonPath(forSkin: $0) }
        // Track sibling names in a set so dedup is O(1) per mesh rather than an
        // O(meshes²) scan of `prim.children` on every append.
        var usedNames = Set(prim.children.map(\.name))
        for meshIndex in node.meshIndices {
            guard plan.scene.meshes.indices.contains(meshIndex) else {
                throw AuthorError.danglingMeshIndex(node: node.name, index: meshIndex)
            }
            let mesh = plan.scene.meshes[meshIndex]
            var name = USDNameSanitizer.sanitize(mesh.name)
            while usedNames.contains(name) { name += "_1" }
            usedNames.insert(name)
            let meshPath = path.appending(name)!  // sanitized + suffixed names stay legal
            prim.children.append(author(mesh, at: meshPath, scene: plan.scene, skeletonPath: skeletonPath, plan: &plan))
        }

        prim.children.append(contentsOf: try node.children.map { try author($0, under: path, plan: &plan) })
        return prim
    }

    private func author(_ mesh: MeshData, at path: PrimPath, scene: IntermediateScene,
                        skeletonPath: PrimPath?, plan: inout AuthorPlan) -> Prim {
        var attributes: [Attribute] = [
            // Author positions as canonical `point3f[]` (`.float3Array`), not
            // `double[]`. The authored snapshot is grafted straight into the
            // live stage without a serialize→reparse, so the in-memory value
            // type is what every geometry reader sees. `GeometryProbe` (and thus
            // check_mesh, world-bbox, raycast) and RealityKit/QuickLook only
            // recognize `point3f[]`; a `double[]` mesh is invisible to them —
            // check_mesh reports "no topology" and bounds compute as empty. Every
            // native authoring path (create_mesh, edit_mesh, sculpt, library
            // insert) already uses `.float3Array`; the importer was the lone
            // outlier. Storage is identical (`[Double]`), only the role type
            // changes.
            Attribute(name: "points", value: .float3Array(mesh.positions.flatMap { [Double($0.x), Double($0.y), Double($0.z)] })),
            Attribute(name: "faceVertexIndices", value: .intArray(mesh.indices.map(Int.init))),
            Attribute(name: "faceVertexCounts", value: .intArray(Array(repeating: 3, count: mesh.triangleCount))),
        ]
        if !mesh.normals.isEmpty {
            attributes.append(Attribute(name: "normals", value: .float3Array(mesh.normals.flatMap { [Double($0.x), Double($0.y), Double($0.z)] })))
        } else {
            // Sources that ship no normals (raw OBJ, some glTF) would otherwise
            // author a mesh that falls back to faceted shading and trips the
            // `mesh.normals` diagnostic. Derive smooth per-vertex normals from
            // the authored topology via MeshKit — the one place this math lives
            // (issue #95).
            let flat = FlatMesh(
                points: mesh.positions.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) },
                faceVertexCounts: Array(repeating: 3, count: mesh.triangleCount),
                faceVertexIndices: mesh.indices.map(Int.init))
            let derived = VertexNormals.smoothFlat(for: flat)
            // Only author when the derivation produced a real direction. A
            // degenerate mesh (e.g. a collapsed triangle) yields an all-zero
            // channel, which is "unshaded" and no better than leaving it off —
            // that stays a `mesh.topology` problem, not a normals one.
            if derived.contains(where: { $0 != 0 }) {
                attributes.append(Attribute(name: "normals", value: .float3Array(derived)))
            }
        }
        if !mesh.uvs.isEmpty {
            attributes.append(Attribute(name: "primvars:st", value: .doubleArray(mesh.uvs.flatMap { [Double($0.x), Double($0.y)] })))
        }
        var relationships: [Relationship] = []
        if let skeletonPath, mesh.isSkinned {
            // glTF JOINTS_0/WEIGHTS_0 are always 4-wide; indices already index
            // the skin's joint order, which matches the Skeleton's `joints`.
            let indices = mesh.jointIndices.flatMap { [Int($0.x), Int($0.y), Int($0.z), Int($0.w)] }
            let weights = mesh.jointWeights.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
            attributes.append(Attribute(
                name: "primvars:skel:jointIndices", value: .intArray(indices),
                metadata: ["elementSize": "4", "interpolation": "\"vertex\""]))
            attributes.append(Attribute(
                name: "primvars:skel:jointWeights", value: .doubleArray(weights),
                metadata: ["elementSize": "4", "interpolation": "\"vertex\""]))
            relationships.append(Relationship(name: "skel:skeleton", targets: [skeletonPath]))
        }
        var metadata: [String: String] = [:]
        if let materialIndex = mesh.materialIndex, scene.materials.indices.contains(materialIndex) {
            metadata["material:binding"] = USDNameSanitizer.sanitize(scene.materials[materialIndex].name)
        }
        return Prim(path: path, typeName: "Mesh", attributes: attributes, relationships: relationships, metadata: metadata)
    }

    private func author(_ material: PBRMaterial, under parent: PrimPath) throws -> Prim {
        guard USDNameSanitizer.isLegal(material.name), let path = parent.appending(material.name) else {
            throw AuthorError.illegalName(material.name)
        }
        var attributes: [Attribute] = [
            Attribute(name: "inputs:diffuseColor", value: .vector([
                Double(material.baseColorFactor.x), Double(material.baseColorFactor.y), Double(material.baseColorFactor.z),
            ])),
            Attribute(name: "inputs:metallic", value: .double(Double(material.metallicFactor))),
            Attribute(name: "inputs:roughness", value: .double(Double(material.roughnessFactor))),
            Attribute(name: "inputs:emissiveColor", value: .vector([
                Double(material.emissiveFactor.x), Double(material.emissiveFactor.y), Double(material.emissiveFactor.z),
            ])),
            Attribute(name: "doubleSided", value: .bool(material.doubleSided)),
        ]
        switch material.alphaMode {
        case .opaque:
            break
        case .mask(let threshold):
            attributes.append(Attribute(name: "inputs:opacityThreshold", value: .double(Double(threshold))))
            attributes.append(Attribute(name: "inputs:opacity", value: .double(Double(material.baseColorFactor.w))))
        case .blend:
            attributes.append(Attribute(name: "inputs:opacity", value: .double(Double(material.baseColorFactor.w))))
        }
        return Prim(path: path, typeName: "Material", attributes: attributes)
    }

    /// simd is column-major; `AttributeValue.matrix4` is row-major.
    static func rowMajor(_ m: simd_float4x4) -> [Double] {
        (0..<4).flatMap { row in (0..<4).map { col in Double(m[col][row]) } }
    }
}
