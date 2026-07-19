import Testing
import Foundation
import simd
import USDCore
@testable import ConversionKit

/// glTF animation/skin import edge cases: malformed channels degrade to
/// warnings (never crashes), reused samplers are deduped, and wrong-typed
/// accessors throw. Built from one custom BIN whose section offsets are
/// computed rather than hand-written.
@Suite("glTF animation edge cases")
struct GLTFAnimationEdgeTests {

    /// A skinned triangle with rotation, translation, and weights sampler
    /// outputs available, so any channel path can be wired up in JSON.
    private func customGLB(animationsJSON: String, jointsType: String = "VEC4",
                           ibmType: String = "MAT4") -> Data {
        let F = GLTFFixtures.self
        // Sections in order; track offsets as we go.
        var bin = Data()
        func add(_ d: Data) -> (off: Int, len: Int) {
            while bin.count % 4 != 0 { bin.append(0) }
            let off = bin.count; bin.append(d); return (off, d.count)
        }
        let pos = add(F.floats(F.trianglePositions))                 // VEC3 ×3
        let wts = add(F.floats([1,0,0,0, 1,0,0,0, 1,0,0,0]))         // VEC4 ×3
        let ibm = add(F.floats(GLTFFixtures.identityMat4 + GLTFFixtures.identityMat4)) // MAT4 ×2
        let inp = add(F.floats([0, 1]))                              // SCALAR ×2
        let rot = add(F.floats([0,0,0,1, 0,0,0.7071068,0.7071068]))  // VEC4 ×2
        let trn = add(F.floats([0,0,0, 1,2,3]))                      // VEC3 ×2
        let wgt = add(F.floats([0, 1]))                              // SCALAR ×2
        let jnt = add(F.ubytes([0,0,0,0, 0,0,0,0, 0,0,0,0]))         // VEC4 ubyte ×3
        let idx = add(F.uint16s([0, 1, 2]))                          // SCALAR ushort ×3

        func bv(_ s: (off: Int, len: Int)) -> String {
            "{\"buffer\":0,\"byteOffset\":\(s.off),\"byteLength\":\(s.len)}"
        }
        let json = """
        {
          "asset": {"version": "2.0"}, "scene": 0,
          "scenes": [{"nodes": [0, 1]}],
          "nodes": [
            {"name":"SkinnedNode","mesh":0,"skin":0},
            {"name":"Hips","children":[2]}, {"name":"Spine"}
          ],
          "meshes": [{"name":"Skin","primitives":[{"attributes":{"POSITION":0,"JOINTS_0":7,"WEIGHTS_0":1},"indices":8}]}],
          "skins": [{"name":"Rig","joints":[1,2],"inverseBindMatrices":2,"skeleton":1}],
          "animations": \(animationsJSON),
          "buffers": [{"byteLength": \(bin.count)}],
          "bufferViews": [
            \(bv(pos)), \(bv(wts)), \(bv(ibm)), \(bv(inp)),
            \(bv(rot)), \(bv(trn)), \(bv(wgt)), \(bv(jnt)), \(bv(idx))
          ],
          "accessors": [
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":1,"componentType":5126,"count":3,"type":"VEC4"},
            {"bufferView":2,"componentType":5126,"count":2,"type":"\(ibmType)"},
            {"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR"},
            {"bufferView":4,"componentType":5126,"count":2,"type":"VEC4"},
            {"bufferView":5,"componentType":5126,"count":2,"type":"VEC3"},
            {"bufferView":6,"componentType":5126,"count":2,"type":"SCALAR"},
            {"bufferView":7,"componentType":5121,"count":3,"type":"\(jointsType)"},
            {"bufferView":8,"componentType":5123,"count":3,"type":"SCALAR"}
          ]
        }
        """
        return F.glb(json: json, bin: bin)
    }

    private func importResult(_ glb: Data) async throws -> ImportResult {
        let url = try GLTFFixtures.write(glb, name: "anim-\(UUID().uuidString).glb")
        return try await GLTFImporter().importAsset(at: url, options: ImportOptions())
    }

    @Test func malformedChannelsDegradeToWarnings() async throws {
        // One animation exercising: missing target node, unsupported path,
        // missing sampler, a valid rotation channel, a valid translation
        // channel, and a second channel reusing sampler 0 (dedup).
        let anims = """
        [{"name":"Mixed","channels":[
          {"sampler":0,"target":{"path":"rotation"}},
          {"sampler":0,"target":{"node":2,"path":"color"}},
          {"sampler":9,"target":{"node":2,"path":"rotation"}},
          {"sampler":0,"target":{"node":2,"path":"rotation"}},
          {"sampler":0,"target":{"node":1,"path":"rotation"}},
          {"sampler":1,"target":{"node":2,"path":"translation"}}
        ],"samplers":[
          {"input":3,"output":4,"interpolation":"LINEAR"},
          {"input":3,"output":5,"interpolation":"LINEAR"}
        ]}]
        """
        let result = try await importResult(customGLB(animationsJSON: anims))
        let msgs = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(msgs.contains("channel without target node"))
        #expect(msgs.contains("unsupported"))
        #expect(msgs.contains("missing sampler"))
        // Two valid samplers survive (rotation reused across channels, translation).
        let anim = try #require(result.scene.animations.first)
        #expect(anim.samplers.count == 2)
        #expect(anim.channels.count >= 3)
    }

    @Test func samplerDecodeFailureWarnsAndSkips() async throws {
        // Sampler input points at the VEC4 accessor (4) — scalarFloats rejects
        // it, decodeSampler catches, warns, and the channel is dropped.
        let anims = """
        [{"name":"Bad","channels":[{"sampler":0,"target":{"node":2,"path":"rotation"}}],
          "samplers":[{"input":4,"output":4,"interpolation":"LINEAR"}]}]
        """
        let result = try await importResult(customGLB(animationsJSON: anims))
        let msgs = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(msgs.contains("sampler decode failed"))
        #expect(result.scene.animations.first?.channels.isEmpty == true)
    }

    @Test func cubicSplineTangentsDroppedWithWarning() async throws {
        // CUBICSPLINE with 2 keys needs 6 output elements; reuse rotation VEC4
        // accessor is only 2, so decode of the stride math still runs the warn
        // path before the count is consulted.
        let anims = """
        [{"name":"Spline","channels":[{"sampler":0,"target":{"node":2,"path":"rotation"}}],
          "samplers":[{"input":3,"output":4,"interpolation":"CUBICSPLINE"}]}]
        """
        let result = try await importResult(customGLB(animationsJSON: anims))
        let msgs = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(msgs.contains("CUBICSPLINE"))
    }

    @Test func inverseBindCountMismatchWarns() async throws {
        // joints [1,2] but we claim only... keep joints 2 and IBM 2 is fine; to
        // mismatch, point IBM at the 3-count positions-shaped accessor instead.
        // Simplest: a skin whose joints list is longer than the IBM count.
        let F = GLTFFixtures.self
        var bin = Data()
        func add(_ d: Data) -> (Int, Int) { while bin.count % 4 != 0 { bin.append(0) }; let o = bin.count; bin.append(d); return (o, d.count) }
        let pos = add(F.floats(F.trianglePositions))
        let ibm = add(F.floats(GLTFFixtures.identityMat4))   // ONE matrix
        let idx = add(F.uint16s([0, 1, 2]))
        let json = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
         "nodes":[{"name":"N","mesh":0,"skin":0},{"name":"J1"},{"name":"J2"}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":2}]}],
         "skins":[{"name":"Rig","joints":[1,2],"inverseBindMatrices":1}],
         "buffers":[{"byteLength":\(bin.count)}],
         "bufferViews":[{"buffer":0,"byteOffset":\(pos.0),"byteLength":\(pos.1)},
           {"buffer":0,"byteOffset":\(ibm.0),"byteLength":\(ibm.1)},
           {"buffer":0,"byteOffset":\(idx.0),"byteLength":\(idx.1)}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
           {"bufferView":1,"componentType":5126,"count":1,"type":"MAT4"},
           {"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"}]}
        """
        let result = try await importResult(F.glb(json: json, bin: bin))
        #expect(result.diagnostics.contains { $0.message.contains("inverseBindMatrices count") })
    }

    @Test func wrongMatrixAccessorTypeThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await importResult(customGLB(animationsJSON: "[]", ibmType: "VEC3"))
        }
    }

    @Test func wrongJointsAccessorTypeThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await importResult(customGLB(animationsJSON: "[]", jointsType: "SCALAR"))
        }
    }

    @Test func morphWeightsAnimationWarnsAtAuthoring() async throws {
        // A weights channel survives import but UsdSkel authoring doesn't yet
        // emit BlendShapes, so the author stage warns rather than dropping it.
        let anims = """
        [{"name":"Morph","channels":[
          {"sampler":0,"target":{"node":2,"path":"rotation"}},
          {"sampler":1,"target":{"node":2,"path":"weights"}}
        ],"samplers":[
          {"input":3,"output":4,"interpolation":"LINEAR"},
          {"input":3,"output":6,"interpolation":"LINEAR"}
        ]}]
        """
        let scene = try await importResult(customGLB(animationsJSON: anims)).scene
        var context = ConversionContext(
            sourceURL: URL(fileURLWithPath: "/in/morph.glb"), scene: scene)
        try await USDAuthorStage().process(&context)
        #expect(context.diagnostics.contains { $0.message.contains("morph-target") })
    }
}
