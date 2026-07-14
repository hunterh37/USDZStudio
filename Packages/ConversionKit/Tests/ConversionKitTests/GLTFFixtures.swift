import Foundation
@testable import ConversionKit

/// In-test GLB/glTF fixture builders — no binary blobs in the repo.
enum GLTFFixtures {

    // MARK: Binary building blocks

    static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func floats(_ values: [Float]) -> Data {
        values.reduce(into: Data()) { data, f in
            data.append(uint32LE(f.bitPattern))
        }
    }

    static func uint16s(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, v in
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    /// Assembles a spec-conformant GLB container from JSON + optional BIN.
    static func glb(json: String, bin: Data? = nil) -> Data {
        var jsonChunk = Data(json.utf8)
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }  // pad with spaces

        var data = Data("glTF".utf8)
        data.append(uint32LE(2))
        data.append(uint32LE(0))  // patched below
        data.append(uint32LE(UInt32(jsonChunk.count)))
        data.append(uint32LE(0x4E4F_534A))
        data.append(jsonChunk)
        if var binChunk = bin {
            while binChunk.count % 4 != 0 { binChunk.append(0) }
            data.append(uint32LE(UInt32(binChunk.count)))
            data.append(uint32LE(0x004E_4942))
            data.append(binChunk)
        }
        var total = data
        total.replaceSubrange(8..<12, with: uint32LE(UInt32(data.count)))
        return total
    }

    // MARK: Canonical triangle

    /// Positions for a unit triangle, three UInt16 indices, VEC2 UVs, normals.
    static let trianglePositions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
    static let triangleNormals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
    static let triangleUVs: [Float] = [0, 0, 1, 0, 0, 1]

    static func triangleBIN() -> Data {
        var bin = floats(trianglePositions)          // offset 0, 36 bytes
        bin.append(floats(triangleNormals))          // offset 36, 36 bytes
        bin.append(floats(triangleUVs))              // offset 72, 24 bytes
        bin.append(uint16s([0, 1, 2]))               // offset 96, 6 bytes
        return bin
    }

    /// A complete single-triangle glTF JSON with material, wired to buffer 0.
    static func triangleJSON(
        bufferURI: String? = nil,
        extraTopLevel: String = "",
        materialJSON: String = """
        {"name":"Red","pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1],"metallicFactor":0.25,"roughnessFactor":0.75},"emissiveFactor":[0.1,0.2,0.3],"doubleSided":true}
        """
    ) -> String {
        let uriField = bufferURI.map { "\"uri\":\"\($0)\"," } ?? ""
        return """
        {
          "asset": {"version": "2.0"},
          "scene": 0,
          "scenes": [{"name": "Scene", "nodes": [0]}],
          "nodes": [{"name": "Tri Node", "mesh": 0, "translation": [1, 2, 3]}],
          "meshes": [{"name": "Tri", "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
            "indices": 3, "material": 0
          }]}],
          "materials": [\(materialJSON)],
          "buffers": [{\(uriField)"byteLength": 102}],
          "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 36},
            {"buffer": 0, "byteOffset": 36, "byteLength": 36},
            {"buffer": 0, "byteOffset": 72, "byteLength": 24},
            {"buffer": 0, "byteOffset": 96, "byteLength": 6}
          ],
          "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
            {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"}
          ]\(extraTopLevel.isEmpty ? "" : ",\n  " + extraTopLevel)
        }
        """
    }

    /// Writes data to a unique temp file and returns its URL.
    static func write(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gltf-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
