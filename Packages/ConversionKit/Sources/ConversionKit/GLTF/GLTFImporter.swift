import Foundation
import simd

/// Native Swift glTF 2.0 / GLB importer — the primary Phase 2 path
/// (specs/conversion-pipeline.md, Supported Inputs). Parses the container
/// and JSON, resolves buffers (GLB BIN chunk, data URIs, external files),
/// and produces an `IntermediateScene`. Unsupported features become
/// warning diagnostics, never silent drops.
public struct GLTFImporter: AssetImporter {
    public static let supportedExtensions = ["glb", "gltf"]

    public init() {}

    public enum GLTFError: Error, Equatable {
        case unreadableFile(String)
        case notGLB
        case unsupportedContainerVersion(UInt32)
        case missingJSONChunk
        case malformedJSON(String)
        case unsupportedVersion(String)
        case requiredExtensionUnsupported(String)
        case indexOutOfRange(what: String, index: Int)
        case bufferOutOfBounds(buffer: Int)
        case missingBufferData(buffer: Int)
        case unsupportedAccessor(String)
        case missingPositions(mesh: String)
    }

    // MARK: Entry point

    public func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw GLTFError.unreadableFile(url.lastPathComponent)
        }

        let jsonData: Data
        var binChunk: Data?
        if raw.count >= 4, raw.prefix(4) == Data("glTF".utf8) {
            (jsonData, binChunk) = try Self.parseGLBContainer(raw)
        } else {
            jsonData = raw
        }

        let document: GLTFDocument
        do {
            document = try JSONDecoder().decode(GLTFDocument.self, from: jsonData)
        } catch {
            throw GLTFError.malformedJSON("\(error)")
        }
        guard document.asset.version.hasPrefix("2") else {
            throw GLTFError.unsupportedVersion(document.asset.version)
        }
        if let required = document.extensionsRequired?.first {
            throw GLTFError.requiredExtensionUnsupported(required)
        }

        var builder = Builder(document: document, baseURL: url.deletingLastPathComponent(), binChunk: binChunk)
        if let used = document.extensionsUsed, !used.isEmpty {
            for ext in used {
                builder.diagnostics.append(Diagnostic(
                    severity: .warning, stage: "parse",
                    message: "extension \(ext) is not supported; content authored without it"))
            }
        }
        let scene = try builder.buildScene(named: url.deletingPathExtension().lastPathComponent)
        return ImportResult(scene: scene, diagnostics: builder.diagnostics)
    }

    // MARK: GLB container

    /// GLB layout: 12-byte header (magic, version, length) then chunks of
    /// (byteLength, type, payload). JSON chunk 0x4E4F534A, BIN 0x004E4942.
    static func parseGLBContainer(_ data: Data) throws -> (json: Data, bin: Data?) {
        guard data.count >= 12 else { throw GLTFError.notGLB }
        let version = data.readUInt32(at: 4)
        guard version == 2 else { throw GLTFError.unsupportedContainerVersion(version) }

        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= data.count {
            let chunkLength = Int(data.readUInt32(at: offset))
            let chunkType = data.readUInt32(at: offset + 4)
            let start = offset + 8
            guard start + chunkLength <= data.count else { throw GLTFError.notGLB }
            let payload = data.subdata(in: start..<(start + chunkLength))
            if chunkType == 0x4E4F_534A { json = payload }
            if chunkType == 0x004E_4942 { bin = payload }
            offset = start + chunkLength
        }
        guard let json else { throw GLTFError.missingJSONChunk }
        return (json, bin)
    }

    // MARK: Builder

    struct Builder {
        let document: GLTFDocument
        let baseURL: URL
        let binChunk: Data?
        var diagnostics: [Diagnostic] = []
        private var bufferCache: [Int: Data] = [:]

        init(document: GLTFDocument, baseURL: URL, binChunk: Data?) {
            self.document = document
            self.baseURL = baseURL
            self.binChunk = binChunk
        }

        mutating func buildScene(named fallbackName: String) throws -> IntermediateScene {
            var scene = IntermediateScene(name: fallbackName)
            for (index, material) in (document.materials ?? []).enumerated() {
                var converted = Self.convert(material, index: index)
                converted.baseColorTexture = textureRef(material.pbrMetallicRoughness?.baseColorTexture)
                converted.metallicRoughnessTexture = textureRef(material.pbrMetallicRoughness?.metallicRoughnessTexture)
                converted.normalTexture = textureRef(material.normalTexture)
                converted.occlusionTexture = textureRef(material.occlusionTexture)
                converted.emissiveTexture = textureRef(material.emissiveTexture)
                scene.materials.append(converted)
            }

            // glTF meshes contain primitives; each primitive becomes one MeshData.
            var meshRanges: [[Int]] = []  // glTF mesh index → IR mesh indices
            for (meshIndex, mesh) in (document.meshes ?? []).enumerated() {
                var range: [Int] = []
                for (primIndex, primitive) in mesh.primitives.enumerated() {
                    let name = mesh.name ?? "Mesh_\(meshIndex)"
                    let mode = primitive.mode ?? 4
                    guard mode == 4 else {
                        diagnostics.append(Diagnostic(
                            severity: .warning, stage: "parse",
                            message: "\(name) primitive \(primIndex): mode \(mode) (non-triangles) skipped"))
                        continue
                    }
                    let data = try buildMesh(primitive, name: mesh.primitives.count > 1 ? "\(name)_\(primIndex)" : name)
                    range.append(scene.meshes.count)
                    scene.meshes.append(data)
                }
                meshRanges.append(range)
            }

            let sceneIndex = document.scene ?? 0
            let rootIndices = (document.scenes?.indices.contains(sceneIndex) == true
                ? document.scenes?[sceneIndex].nodes : nil)
                ?? Array((document.nodes ?? []).indices)
            scene.rootNodes = try rootIndices.map { try buildNode($0, meshRanges: meshRanges, visited: []) }
            scene.skins = try buildSkins()
            scene.animations = buildAnimations()
            return scene
        }

        // MARK: Skins & animations

        private mutating func buildSkins() throws -> [Skin] {
            try (document.skins ?? []).enumerated().map { index, skin in
                var result = Skin(name: skin.name ?? "Skin_\(index)", joints: skin.joints, skeletonRoot: skin.skeleton)
                if let ibm = skin.inverseBindMatrices {
                    result.inverseBindMatrices = try mat4(accessor: ibm)
                    if result.inverseBindMatrices.count != skin.joints.count {
                        diagnostics.append(Diagnostic(
                            severity: .warning, stage: "parse",
                            message: "\(result.name): inverseBindMatrices count \(result.inverseBindMatrices.count) ≠ joint count \(skin.joints.count)"))
                    }
                }
                return result
            }
        }

        private mutating func buildAnimations() -> [Animation] {
            (document.animations ?? []).enumerated().map { index, anim in
                buildAnimation(anim, index: index)
            }
        }

        private mutating func buildAnimation(_ anim: GLTFDocument.Animation, index: Int) -> Animation {
            let name = anim.name ?? "Animation_\(index)"
            var samplers: [AnimationSampler] = []
            var remap: [Int: Int] = [:]  // glTF sampler index → IR sampler index
            var channels: [AnimationChannel] = []
            for channel in anim.channels {
                guard let node = channel.target.node else {
                    warn(name, "channel without target node skipped")
                    continue
                }
                let path: AnimationPath
                switch channel.target.path {
                case "translation": path = .translation
                case "rotation": path = .rotation
                case "scale": path = .scale
                case "weights": path = .weights
                default:
                    warn(name, "channel path \(channel.target.path) unsupported; skipped")
                    continue
                }
                guard anim.samplers.indices.contains(channel.sampler) else {
                    warn(name, "channel references missing sampler \(channel.sampler); skipped")
                    continue
                }
                let irIndex: Int
                if let existing = remap[channel.sampler] {
                    irIndex = existing
                } else if let decoded = decodeSampler(anim.samplers[channel.sampler], path: path, animName: name) {
                    irIndex = samplers.count
                    samplers.append(decoded)
                    remap[channel.sampler] = irIndex
                } else {
                    continue
                }
                channels.append(AnimationChannel(targetNodeID: node, path: path, samplerIndex: irIndex))
            }
            return Animation(name: name, channels: channels, samplers: samplers)
        }

        private mutating func decodeSampler(
            _ sampler: GLTFDocument.Animation.Sampler, path: AnimationPath, animName: String
        ) -> AnimationSampler? {
            do {
                var interpolation = Interpolation(rawValue: sampler.interpolation ?? "LINEAR") ?? .linear
                let times = try scalarFloats(accessor: sampler.input)
                // CUBICSPLINE stores (in-tangent, value, out-tangent) per key; we
                // keep the value and drop tangents (warned once), so it degrades
                // to LINEAR rather than being silently lost.
                let stride = interpolation == .cubicSpline ? 3 : 1
                if interpolation == .cubicSpline {
                    warn(animName, "CUBICSPLINE tangents dropped; keys sampled as LINEAR")
                }
                let output: AnimationSampler.Output
                switch path {
                case .translation, .scale:
                    let f = try floatVectors(accessor: sampler.output, components: 3)
                    let raw = (0..<f.count / 3).map { SIMD3(f[$0 * 3], f[$0 * 3 + 1], f[$0 * 3 + 2]) }
                    output = .vec3(pickValues(raw, stride: stride))
                case .rotation:
                    let f = try floatVectors(accessor: sampler.output, components: 4)
                    let raw = (0..<f.count / 4).map { SIMD4(f[$0 * 4], f[$0 * 4 + 1], f[$0 * 4 + 2], f[$0 * 4 + 3]) }
                    output = .rotation(pickValues(raw, stride: stride))
                case .weights:
                    output = .scalar(try scalarFloats(accessor: sampler.output))
                }
                if interpolation == .cubicSpline { interpolation = .linear }
                return AnimationSampler(input: times, interpolation: interpolation, output: output)
            } catch {
                warn(animName, "sampler decode failed (\(error)); skipped")
                return nil
            }
        }

        /// For CUBICSPLINE (stride 3) picks the middle (value) element of each
        /// tangent triple; otherwise returns the array unchanged.
        private func pickValues<T>(_ values: [T], stride: Int) -> [T] {
            guard stride > 1 else { return values }
            return Swift.stride(from: 1, to: values.count, by: stride).map { values[$0] }
        }

        private mutating func warn(_ animName: String, _ message: String) {
            diagnostics.append(Diagnostic(severity: .warning, stage: "parse", message: "\(animName): \(message)"))
        }

        // MARK: Nodes

        private func buildNode(_ index: Int, meshRanges: [[Int]], visited: Set<Int>) throws -> SceneNode {
            guard let nodes = document.nodes, nodes.indices.contains(index), !visited.contains(index) else {
                throw GLTFError.indexOutOfRange(what: "node", index: index)
            }
            let node = nodes[index]
            var result = SceneNode(name: node.name ?? "Node_\(index)")
            result.id = index
            result.skinIndex = node.skin
            result.transform = Self.transform(of: node)
            if let mesh = node.mesh {
                guard meshRanges.indices.contains(mesh) else {
                    throw GLTFError.indexOutOfRange(what: "mesh", index: mesh)
                }
                result.meshIndices = meshRanges[mesh]
            }
            result.children = try (node.children ?? []).map {
                try buildNode($0, meshRanges: meshRanges, visited: visited.union([index]))
            }
            return result
        }

        static func transform(of node: GLTFDocument.Node) -> simd_float4x4 {
            if let m = node.matrix, m.count == 16 {
                return simd_float4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]),
                    SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]),
                    SIMD4(m[12], m[13], m[14], m[15])
                ))
            }
            var matrix = matrix_identity_float4x4
            if let r = node.rotation, r.count == 4 {
                matrix = simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            }
            if let s = node.scale, s.count == 3 {
                matrix = matrix * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
            }
            if let t = node.translation, t.count == 3 {
                matrix.columns.3 = SIMD4(t[0], t[1], t[2], 1) + SIMD4(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, 0)
            }
            return matrix
        }

        // MARK: Meshes

        private mutating func buildMesh(_ primitive: GLTFDocument.Primitive, name: String) throws -> MeshData {
            guard let positionAccessor = primitive.attributes["POSITION"] else {
                throw GLTFError.missingPositions(mesh: name)
            }
            var mesh = MeshData(name: name, materialIndex: primitive.material)
            if let material = primitive.material,
               !(document.materials ?? []).indices.contains(material) {
                throw GLTFError.indexOutOfRange(what: "material", index: material)
            }

            let positions = try floatVectors(accessor: positionAccessor, components: 3)
            mesh.positions = stride(from: 0, to: positions.count, by: 3).map { SIMD3(positions[$0], positions[$0 + 1], positions[$0 + 2]) }
            if let normal = primitive.attributes["NORMAL"] {
                let n = try floatVectors(accessor: normal, components: 3)
                mesh.normals = stride(from: 0, to: n.count, by: 3).map { SIMD3(n[$0], n[$0 + 1], n[$0 + 2]) }
            }
            if let uv = primitive.attributes["TEXCOORD_0"] {
                let uvs = try floatVectors(accessor: uv, components: 2)
                mesh.uvs = stride(from: 0, to: uvs.count, by: 2).map { SIMD2(uvs[$0], uvs[$0 + 1]) }
            }
            if let joints = primitive.attributes["JOINTS_0"] {
                mesh.jointIndices = try jointIndices(accessor: joints)
            }
            if let weights = primitive.attributes["WEIGHTS_0"] {
                let w = try floatVectors(accessor: weights, components: 4)
                mesh.jointWeights = stride(from: 0, to: w.count, by: 4).map { SIMD4(w[$0], w[$0 + 1], w[$0 + 2], w[$0 + 3]) }
            }
            let handled: Set = ["POSITION", "NORMAL", "TEXCOORD_0", "JOINTS_0", "WEIGHTS_0"]
            for attribute in primitive.attributes.keys.sorted() where !handled.contains(attribute) {
                diagnostics.append(Diagnostic(
                    severity: .warning, stage: "parse",
                    message: "\(name): vertex attribute \(attribute) not yet supported; dropped"))
            }

            if let indices = primitive.indices {
                mesh.indices = try scalarIndices(accessor: indices)
            } else {
                mesh.indices = Array(0..<UInt32(mesh.positions.count))
            }
            return mesh
        }

        // MARK: Accessors

        private mutating func accessor(_ index: Int) throws -> GLTFDocument.Accessor {
            guard let accessors = document.accessors, accessors.indices.contains(index) else {
                throw GLTFError.indexOutOfRange(what: "accessor", index: index)
            }
            return accessors[index]
        }

        /// Reads a float VEC2/VEC3/VEC4 accessor (componentType 5126), honoring
        /// byteStride, into a single flat, densely-packed `[Float]` buffer of
        /// `count * components` elements. Callers slice it into SIMD vectors —
        /// reading straight into one pre-sized buffer avoids the per-vertex
        /// inner-array allocation this incurred when it returned `[[Float]]`.
        private mutating func floatVectors(accessor index: Int, components: Int) throws -> [Float] {
            let accessor = try self.accessor(index)
            let expectedType = ["VEC2", "VEC3", "VEC4"][components - 2]
            guard accessor.componentType == 5126, accessor.type == expectedType else {
                throw GLTFError.unsupportedAccessor("accessor \(index): \(accessor.type)/\(accessor.componentType), expected \(expectedType)/float")
            }
            let bytes = try viewData(for: accessor, elementSize: components * 4)
            var out = [Float]()
            out.reserveCapacity(accessor.count * components)
            for element in 0..<accessor.count {
                let base = bytes.start + element * bytes.stride
                for component in 0..<components {
                    out.append(bytes.data.readFloat(at: base + component * 4))
                }
            }
            return out
        }

        /// Reads a float SCALAR accessor (5126) — animation key times, weights.
        private mutating func scalarFloats(accessor index: Int) throws -> [Float] {
            let accessor = try self.accessor(index)
            guard accessor.componentType == 5126, accessor.type == "SCALAR" else {
                throw GLTFError.unsupportedAccessor("scalar accessor \(index): \(accessor.type)/\(accessor.componentType), expected SCALAR/float")
            }
            let bytes = try viewData(for: accessor, elementSize: 4)
            return (0..<accessor.count).map { bytes.data.readFloat(at: bytes.start + $0 * bytes.stride) }
        }

        /// Reads a MAT4 float accessor (5126) — inverse bind matrices. glTF
        /// matrices are column-major, matching `simd_float4x4(columns:)`.
        private mutating func mat4(accessor index: Int) throws -> [simd_float4x4] {
            let accessor = try self.accessor(index)
            guard accessor.componentType == 5126, accessor.type == "MAT4" else {
                throw GLTFError.unsupportedAccessor("matrix accessor \(index): \(accessor.type)/\(accessor.componentType), expected MAT4/float")
            }
            let bytes = try viewData(for: accessor, elementSize: 64)
            return (0..<accessor.count).map { element in
                let base = bytes.start + element * bytes.stride
                let m = (0..<16).map { bytes.data.readFloat(at: base + $0 * 4) }
                return simd_float4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            }
        }

        /// Reads a VEC4 joint-index accessor: ubyte(5121) or ushort(5123).
        private mutating func jointIndices(accessor index: Int) throws -> [SIMD4<UInt16>] {
            let accessor = try self.accessor(index)
            let size: Int
            switch accessor.componentType {
            case 5121: size = 1
            case 5123: size = 2
            default:
                throw GLTFError.unsupportedAccessor("joints accessor \(index): componentType \(accessor.componentType)")
            }
            guard accessor.type == "VEC4" else {
                throw GLTFError.unsupportedAccessor("joints accessor \(index): type \(accessor.type), expected VEC4")
            }
            let bytes = try viewData(for: accessor, elementSize: size * 4)
            return (0..<accessor.count).map { element in
                let base = bytes.start + element * bytes.stride
                let comps = (0..<4).map { component -> UInt16 in
                    let at = base + component * size
                    return size == 1 ? UInt16(bytes.data[bytes.data.startIndex + at]) : bytes.data.readUInt16(at: at)
                }
                return SIMD4(comps[0], comps[1], comps[2], comps[3])
            }
        }

        /// Reads a SCALAR index accessor: ubyte(5121)/ushort(5123)/uint(5125).
        private mutating func scalarIndices(accessor index: Int) throws -> [UInt32] {
            let accessor = try self.accessor(index)
            guard accessor.type == "SCALAR" else {
                throw GLTFError.unsupportedAccessor("index accessor \(index): type \(accessor.type)")
            }
            let size: Int
            switch accessor.componentType {
            case 5121: size = 1
            case 5123: size = 2
            case 5125: size = 4
            default:
                throw GLTFError.unsupportedAccessor("index accessor \(index): componentType \(accessor.componentType)")
            }
            let bytes = try viewData(for: accessor, elementSize: size)
            return (0..<accessor.count).map { element in
                let at = bytes.start + element * bytes.stride
                switch size {
                case 1: return UInt32(bytes.data[bytes.data.startIndex + at])
                case 2: return UInt32(bytes.data.readUInt16(at: at))
                default: return bytes.data.readUInt32(at: at)
                }
            }
        }

        private mutating func viewData(
            for accessor: GLTFDocument.Accessor, elementSize: Int
        ) throws -> (data: Data, start: Int, stride: Int) {
            guard let viewIndex = accessor.bufferView,
                  let views = document.bufferViews, views.indices.contains(viewIndex) else {
                throw GLTFError.indexOutOfRange(what: "bufferView", index: accessor.bufferView ?? -1)
            }
            let view = views[viewIndex]
            let data = try bufferData(view.buffer)
            let stride = view.byteStride ?? elementSize
            let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
            let end = start + (accessor.count - 1) * stride + elementSize
            guard accessor.count > 0, end <= data.count else {
                throw GLTFError.bufferOutOfBounds(buffer: view.buffer)
            }
            return (data, start, stride)
        }

        // MARK: Buffers & textures

        private mutating func bufferData(_ index: Int) throws -> Data {
            if let cached = bufferCache[index] { return cached }
            guard let buffers = document.buffers, buffers.indices.contains(index) else {
                throw GLTFError.indexOutOfRange(what: "buffer", index: index)
            }
            let buffer = buffers[index]
            let data: Data
            if let uri = buffer.uri {
                if let decoded = Self.decodeDataURI(uri) {
                    data = decoded
                } else if let loaded = try? Data(contentsOf: baseURL.appendingPathComponent(uri)) {
                    data = loaded
                } else {
                    throw GLTFError.missingBufferData(buffer: index)
                }
            } else if let binChunk, index == 0 {
                data = binChunk
            } else {
                throw GLTFError.missingBufferData(buffer: index)
            }
            guard data.count >= buffer.byteLength else {
                throw GLTFError.bufferOutOfBounds(buffer: index)
            }
            bufferCache[index] = data
            return data
        }

        static func decodeDataURI(_ uri: String) -> Data? {
            guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
            guard uri[..<comma].hasSuffix(";base64") else { return nil }
            return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
        }

        mutating func textureRef(_ info: GLTFDocument.TextureInfo?) -> TextureRef? {
            guard let info,
                  let textures = document.textures, textures.indices.contains(info.index),
                  let source = textures[info.index].source,
                  let images = document.images, images.indices.contains(source) else {
                if info != nil {
                    diagnostics.append(Diagnostic(
                        severity: .warning, stage: "parse",
                        message: "texture \(info!.index): unresolvable image reference; dropped"))
                }
                return nil
            }
            let image = images[source]
            if let uri = image.uri {
                if let decoded = Self.decodeDataURI(uri) {
                    return TextureRef(source: .data(decoded), mimeType: image.mimeType)
                }
                return TextureRef(source: .uri(uri), mimeType: image.mimeType)
            }
            if let viewIndex = image.bufferView,
               let views = document.bufferViews, views.indices.contains(viewIndex),
               let data = try? bufferData(views[viewIndex].buffer) {
                let view = views[viewIndex]
                let start = view.byteOffset ?? 0
                if start + view.byteLength <= data.count {
                    return TextureRef(
                        source: .data(data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + view.byteLength))),
                        mimeType: image.mimeType)
                }
            }
            diagnostics.append(Diagnostic(
                severity: .warning, stage: "parse",
                message: "image \(source): no readable bytes; dropped"))
            return nil
        }

        // MARK: Materials

        static func convert(_ material: GLTFDocument.Material, index: Int) -> PBRMaterial {
            var result = PBRMaterial(name: material.name ?? "Material_\(index)")
            if let pbr = material.pbrMetallicRoughness {
                if let f = pbr.baseColorFactor, f.count == 4 {
                    result.baseColorFactor = SIMD4(f[0], f[1], f[2], f[3])
                }
                result.metallicFactor = pbr.metallicFactor ?? 1
                result.roughnessFactor = pbr.roughnessFactor ?? 1
            }
            if let f = material.emissiveFactor, f.count == 3 {
                result.emissiveFactor = SIMD3(f[0], f[1], f[2])
            }
            result.normalScale = material.normalTexture?.scale ?? 1
            switch material.alphaMode {
            case "MASK": result.alphaMode = .mask(threshold: material.alphaCutoff ?? 0.5)
            case "BLEND": result.alphaMode = .blend
            default: result.alphaMode = .opaque
            }
            result.doubleSided = material.doubleSided ?? false
            return result
        }
    }
}

// MARK: - Little-endian readers

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func readUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func readFloat(at offset: Int) -> Float {
        Float(bitPattern: readUInt32(at: offset))
    }
}
