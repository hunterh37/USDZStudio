import Foundation
import simd
import USDCore

/// Stage 8 of the standard sequence: IntermediateScene → USD stage
/// (specs/conversion-pipeline.md). Authors a value-typed `StageSnapshot`;
/// USDBridge serializes it to usdz in the `package` stage.
public struct USDAuthorStage: ConversionStage {
    public let id = "usd-author"

    public init() {}

    public enum AuthorError: Error, Equatable {
        case illegalName(String)
        case danglingMeshIndex(node: String, index: Int)
    }

    public func process(_ context: inout ConversionContext) async throws {
        let scene = context.scene
        let rootName = USDNameSanitizer.isLegal(scene.name) ? scene.name : "Root"
        let rootPath = PrimPath("/\(rootName)")!  // rootName is legal by construction

        var root = Prim(path: rootPath, typeName: "Xform")
        root.children = try scene.rootNodes.map { try author($0, under: rootPath, scene: scene) }

        // Materials live under /<Root>/Materials, referenced by mesh index.
        if !scene.materials.isEmpty {
            let materialsPath = rootPath.appending("Materials")!  // literal legal name
            var materialsScope = Prim(path: materialsPath, typeName: "Scope")
            materialsScope.children = try scene.materials.map { try author($0, under: materialsPath) }
            root.children.append(materialsScope)
        }

        context.authoredStage = StageSnapshot(
            sourceURL: context.sourceURL,
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: rootName),
            rootPrims: [root]
        )
    }

    private func author(_ node: SceneNode, under parent: PrimPath, scene: IntermediateScene) throws -> Prim {
        guard USDNameSanitizer.isLegal(node.name), let path = parent.appending(node.name) else {
            throw AuthorError.illegalName(node.name)
        }
        var prim = Prim(path: path, typeName: "Xform")
        prim.attributes = [Attribute(name: "xformOp:transform", value: .matrix4(rowMajor(node.transform)))]

        for meshIndex in node.meshIndices {
            guard scene.meshes.indices.contains(meshIndex) else {
                throw AuthorError.danglingMeshIndex(node: node.name, index: meshIndex)
            }
            let mesh = scene.meshes[meshIndex]
            var name = USDNameSanitizer.sanitize(mesh.name)
            while prim.children.contains(where: { $0.name == name }) { name += "_1" }
            let meshPath = path.appending(name)!  // sanitized + suffixed names stay legal
            prim.children.append(author(mesh, at: meshPath, scene: scene))
        }

        prim.children.append(contentsOf: try node.children.map { try author($0, under: path, scene: scene) })
        return prim
    }

    private func author(_ mesh: MeshData, at path: PrimPath, scene: IntermediateScene) -> Prim {
        var attributes: [Attribute] = [
            Attribute(name: "points", value: .doubleArray(mesh.positions.flatMap { [Double($0.x), Double($0.y), Double($0.z)] })),
            Attribute(name: "faceVertexIndices", value: .intArray(mesh.indices.map(Int.init))),
            Attribute(name: "faceVertexCounts", value: .intArray(Array(repeating: 3, count: mesh.triangleCount))),
        ]
        if !mesh.normals.isEmpty {
            attributes.append(Attribute(name: "normals", value: .doubleArray(mesh.normals.flatMap { [Double($0.x), Double($0.y), Double($0.z)] })))
        }
        if !mesh.uvs.isEmpty {
            attributes.append(Attribute(name: "primvars:st", value: .doubleArray(mesh.uvs.flatMap { [Double($0.x), Double($0.y)] })))
        }
        var metadata: [String: String] = [:]
        if let materialIndex = mesh.materialIndex, scene.materials.indices.contains(materialIndex) {
            metadata["material:binding"] = USDNameSanitizer.sanitize(scene.materials[materialIndex].name)
        }
        return Prim(path: path, typeName: "Mesh", attributes: attributes, metadata: metadata)
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
    private func rowMajor(_ m: simd_float4x4) -> [Double] {
        (0..<4).flatMap { row in (0..<4).map { col in Double(m[col][row]) } }
    }
}
