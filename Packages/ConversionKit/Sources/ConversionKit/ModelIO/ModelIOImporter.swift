import CoreGraphics
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

/// OBJ (+MTL), STL, PLY, and DAE import via ModelIO/SceneKit
/// (specs/conversion-pipeline.md — Supported Inputs). OBJ materials are
/// mapped MTL → PBR; STL/PLY are geometry-only and fall through to the
/// default material; DAE is best-effort through SceneKit.
public struct ModelIOImporter: AssetImporter {
    public static let supportedExtensions = ["obj", "stl", "ply", "dae"]

    public init() {}

    public enum ImportError: Error, Equatable {
        case fileNotFound(String)
        case unreadable(String)
        case emptyScene(String)
    }

    public func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileNotFound(url.lastPathComponent)
        }
        let asset: MDLAsset
        if url.pathExtension.lowercased() == "dae" {
            guard let scnScene = try? SCNScene(url: url, options: [.checkConsistency: false]) else {
                throw ImportError.unreadable(url.lastPathComponent)
            }
            // coverage:disable — SceneKit's DAE loader is an XPC service that is
            // unavailable in headless CI; the SCNScene→MDLAsset path is covered
            // via importsSceneKitBackedAsset with a programmatic scene.
            asset = MDLAsset(scnScene: scnScene)
        } else {
            asset = MDLAsset(url: url)
        }
        return try Self.importAsset(asset, name: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent)
    }

    /// Shared MDLAsset → IR conversion; also the entry point for
    /// SceneKit-originated assets (DAE goes SCNScene → MDLAsset → here).
    static func importAsset(_ asset: MDLAsset, name: String, fileName: String) throws -> ImportResult {
        var builder = Builder()
        for index in 0..<asset.count {
            if let node = builder.convert(asset.object(at: index)) {
                builder.rootNodes.append(node)
            }
        }
        guard !builder.meshes.isEmpty else {
            throw ImportError.emptyScene(fileName)
        }
        let scene = IntermediateScene(
            name: name,
            rootNodes: builder.rootNodes,
            meshes: builder.meshes,
            materials: builder.materials
        )
        return ImportResult(scene: scene, diagnostics: builder.diagnostics)
    }

    // MARK: - MDL object graph → IntermediateScene

    struct Builder {
        var rootNodes: [SceneNode] = []
        var meshes: [MeshData] = []
        var materials: [PBRMaterial] = []
        var diagnostics: [Diagnostic] = []
        /// Dedupe identical materials by name (MTL reuse across submeshes).
        private var materialIndexByName: [String: Int] = [:]

        mutating func convert(_ object: MDLObject) -> SceneNode? {
            var node = SceneNode(name: object.name.isEmpty ? "Node" : object.name)
            if let transform = object.transform {
                node.transform = transform.matrix
            }
            if let mesh = object as? MDLMesh {
                node.meshIndices = convert(mesh: mesh)
            }
            for child in object.children.objects {
                if let childNode = convert(child) {
                    node.children.append(childNode)
                }
            }
            if node.meshIndices.isEmpty && node.children.isEmpty && !(object is MDLMesh) {
                // Cameras/lights and other non-geometry leaves: not part of the IR.
                return nil
            }
            return node
        }

        /// One MeshData per triangle submesh; non-triangle submeshes warn and skip.
        private mutating func convert(mesh: MDLMesh) -> [Int] {
            let positions = ModelIOImporter.float3Attribute(mesh, MDLVertexAttributePosition) ?? []
            let normals = ModelIOImporter.float3Attribute(mesh, MDLVertexAttributeNormal) ?? []
            let uvs = ModelIOImporter.float2Attribute(mesh, MDLVertexAttributeTextureCoordinate) ?? []
            guard !positions.isEmpty else {
                diagnostics.append(Diagnostic(
                    severity: .warning, stage: "modelio-import",
                    message: "mesh \"\(mesh.name)\" has no positions — skipped"))
                return []
            }

            var produced: [Int] = []
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for (index, submesh) in submeshes.enumerated() {
                guard submesh.geometryType == .triangles else {
                    diagnostics.append(Diagnostic(
                        severity: .warning, stage: "modelio-import",
                        message: "submesh \(index) of \"\(mesh.name)\" is not triangles — skipped"))
                    continue
                }
                let map = submesh.indexBuffer.map()
                let indices = ModelIOImporter.convertIndices(
                    Data(bytes: map.bytes, count: submesh.indexBuffer.length),
                    type: submesh.indexType,
                    count: submesh.indexCount
                )
                var data = MeshData(
                    name: submeshes.count == 1 ? mesh.name : "\(mesh.name)_\(index)",
                    positions: positions,
                    normals: normals,
                    uvs: uvs,
                    indices: indices
                )
                if let material = submesh.material {
                    data.materialIndex = register(material)
                }
                meshes.append(data)
                produced.append(meshes.count - 1)
            }
            return produced
        }

        private mutating func register(_ material: MDLMaterial) -> Int {
            if let existing = materialIndexByName[material.name] { return existing }
            materials.append(ModelIOImporter.convert(material))
            materialIndexByName[material.name] = materials.count - 1
            return materials.count - 1
        }
    }

    // MARK: - Material mapping (MTL/SceneKit → PBRMaterial)

    static func convert(_ material: MDLMaterial) -> PBRMaterial {
        var out = PBRMaterial(name: material.name.isEmpty ? "Material" : material.name)
        // ModelIO's MTL defaults (metallic 0, roughness ~0.9 diffuse look)
        // beat glTF's metallic-1 default for these legacy formats.
        out.metallicFactor = 0
        out.roughnessFactor = 1

        if let property = material.property(with: .baseColor) {
            if let texture = textureRef(property) {
                out.baseColorTexture = texture
            } else if let color = colorValue(property) {
                out.baseColorFactor = color
            }
        }
        if let property = material.property(with: .roughness), property.type == .float {
            out.roughnessFactor = property.floatValue
        }
        if let property = material.property(with: .metallic), property.type == .float {
            out.metallicFactor = property.floatValue
        }
        if let property = material.property(with: .emission), let color = colorValue(property) {
            out.emissiveFactor = SIMD3(color.x, color.y, color.z)
        }
        if let property = material.property(with: .tangentSpaceNormal), let texture = textureRef(property) {
            out.normalTexture = texture
        }
        if let property = material.property(with: .opacity), property.type == .float, property.floatValue < 1 {
            out.baseColorFactor.w = property.floatValue
            out.alphaMode = .blend
        }
        return out
    }

    /// MTL texture references arrive as string paths or URLs.
    static func textureRef(_ property: MDLMaterialProperty) -> TextureRef? {
        switch property.type {
        case .string:
            guard let string = property.stringValue, !string.isEmpty else { return nil }
            return TextureRef(source: .uri(string))
        case .URL:
            guard let url = property.urlValue else { return nil }
            return TextureRef(source: .uri(url.lastPathComponent))
        default:
            return nil
        }
    }

    static func colorValue(_ property: MDLMaterialProperty) -> SIMD4<Float>? {
        switch property.type {
        case .float3:
            let v = property.float3Value
            return SIMD4(v.x, v.y, v.z, 1)
        case .float4:
            return property.float4Value
        case .color:
            guard let color = property.color,
                  let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
                  let components = srgb.components, components.count >= 3 else { return nil }
            let alpha = components.count >= 4 ? Float(components[3]) : 1
            return SIMD4(Float(components[0]), Float(components[1]), Float(components[2]), alpha)
        default:
            return nil
        }
    }

    // MARK: - Buffer decoding (pure, unit-tested directly)

    static func convertIndices(_ data: Data, type: MDLIndexBitDepth, count: Int) -> [UInt32] {
        func read<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> [UInt32] {
            let size = MemoryLayout<T>.size
            guard data.count >= count * size else { return [] }
            return (0..<count).map { element in
                var value: T = 0
                _ = withUnsafeMutableBytes(of: &value) { destination in
                    data.copyBytes(to: destination, from: (element * size)..<((element + 1) * size))
                }
                return UInt32(value)
            }
        }
        switch type {
        case .uInt8: return read(UInt8.self)
        case .uInt16: return read(UInt16.self)
        case .uInt32: return read(UInt32.self)
        default: return []
        }
    }

    static func float3Attribute(_ mesh: MDLMesh, _ name: String) -> [SIMD3<Float>]? {
        floats(mesh, name, components: 3, as: .float3).map { $0.map { SIMD3($0[0], $0[1], $0[2]) } }
    }

    static func float2Attribute(_ mesh: MDLMesh, _ name: String) -> [SIMD2<Float>]? {
        floats(mesh, name, components: 2, as: .float2).map { $0.map { SIMD2($0[0], $0[1]) } }
    }

    private static func floats(
        _ mesh: MDLMesh, _ name: String, components: Int, as format: MDLVertexFormat
    ) -> [[Float]]? {
        guard mesh.vertexCount > 0,
              let attribute = mesh.vertexAttributeData(forAttributeNamed: name, as: format) else {
            return nil
        }
        var out: [[Float]] = []
        out.reserveCapacity(mesh.vertexCount)
        var pointer = attribute.dataStart
        for _ in 0..<mesh.vertexCount {
            let values = pointer.assumingMemoryBound(to: Float.self)
            out.append((0..<components).map { values[$0] })
            pointer += attribute.stride
        }
        return out
    }
}
