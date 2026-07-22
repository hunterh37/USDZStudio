import Foundation
import Testing
@testable import SculptKit

@Suite struct SpecModelTests {

    // MARK: - ShapeKind

    @Test func shapeKindAuthorsGeometry() {
        #expect(ShapeKind.group.authorsGeometry == false)
        #expect(ShapeKind.primitive(.box).authorsGeometry == true)
        #expect(ShapeKind.library(entryID: "prim.cube").authorsGeometry == true)
        #expect(ShapeKind.Primitive.allCases.count == 5)
    }

    @Test func shapeKindRoundTripsAllCases() throws {
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for k in [ShapeKind.group, .primitive(.sphere), .library(entryID: "rock")] {
            #expect(try dec.decode(ShapeKind.self, from: enc.encode(k)) == k)
        }
    }

    @Test func shapeKindDecodesLegacySynthesizedForm() throws {
        let dec = JSONDecoder()
        func decode(_ s: String) throws -> ShapeKind {
            try dec.decode(ShapeKind.self, from: Data(s.utf8))
        }
        #expect(try decode(#"{"group":{}}"#) == .group)
        #expect(try decode(#"{"primitive":{"_0":"cone"}}"#) == .primitive(.cone))
        #expect(try decode(#"{"library":{"entryID":"rock"}}"#) == .library(entryID: "rock"))
    }

    // MARK: - ComponentNode / spec derivations

    static func sampleSpec() -> ObjectSculptSpec {
        let leaf = ComponentNode(
            name: "Lid", shape: .primitive(.cylinder), materialID: "wood")
        let body = ComponentNode(
            name: "Body", shape: .primitive(.cylinder),
            materialID: "wood", children: [leaf])
        let root = ComponentNode(name: "Barrel", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Barrel", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "wood", baseColor: [0.4, 0.2, 0.1])])
    }

    @Test func specDerivations() {
        let spec = Self.sampleSpec()
        #expect(spec.componentCount == 3)
        #expect(spec.allNodes.map(\.name) == ["Barrel", "Body", "Lid"])
        #expect(spec.materialIDs == ["wood"])
        // Barrel is a group (not geometry); Body has a child; only Lid is a geometry leaf.
        #expect(spec.geometryLeaves.map(\.name) == ["Lid"])
        #expect(spec.root.flattened.count == 3)
        #expect(spec.root.id == "Barrel")   // Identifiable id == name
    }

    @Test func specRoundTrips() throws {
        var spec = Self.sampleSpec()
        spec.sockets = [Socket(name: "top", translation: [0, 1, 0])]
        spec.detailInventory.upsert(DetailItem(id: "d1", description: "wood grain", kind: .linework, mappedTo: "wood"))
        spec.materials[0].emissive = [0, 0, 0]
        spec.reviewHistory = [PassReview(pass: .blockout, decision: .continue, score: 0.9,
                                         renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png", note: "ok")]
        spec.root.children[0].repetition = RepetitionSystem(name: "hoop", count: 3, step: [0, 0.3, 0])
        let data = try spec.encoded()
        let decoded = try ObjectSculptSpec.decoded(from: data)
        #expect(decoded == spec)
    }

    // MARK: - DetailInventory

    @Test func detailInventoryMapping() {
        var inv = DetailInventory()
        inv.upsert(DetailItem(id: "a", description: "bevel", kind: .bevel))
        inv.upsert(DetailItem(id: "b", description: "gloss", kind: .gloss))
        #expect(inv.isFullyMapped == false)
        #expect(inv.unmapped.count == 2)
        #expect(inv.mapped.isEmpty)

        // upsert existing id replaces.
        inv.upsert(DetailItem(id: "a", description: "big bevel", kind: .bevel))
        #expect(inv.items.count == 2)
        #expect(inv.items.first?.description == "big bevel")

        #expect(inv.map(id: "a", to: "Body") == true)
        #expect(inv.map(id: "missing", to: "X") == false)
        #expect(inv.items.first(where: { $0.id == "a" })?.isMapped == true)

        inv.map(id: "b", to: "mat")
        #expect(inv.isFullyMapped)
        #expect(inv.mapped.count == 2)
        #expect(DetailKind.allCases.count == 8)
    }

    // MARK: - SculptPass

    @Test func passOrderingAndNavigation() {
        #expect(SculptPass.allCases.count == 8)
        #expect(SculptPass.blockout.index == 0)
        #expect(SculptPass.blockout.next == .structural)
        #expect(SculptPass.optimization.next == nil)
        #expect(SculptPass.blockout < SculptPass.material)
        for pass in SculptPass.allCases {
            #expect(!pass.responsibility.isEmpty)
        }
    }

    @Test func passDecisionEquatable() {
        #expect(PassDecision.continue == PassDecision.continue)
        #expect(PassDecision.stop != PassDecision.continue)
    }

    // MARK: - Material texture channels

    @Test func materialHasTextures() {
        let flat = MaterialSpec(id: "m", baseColor: [1, 0, 0])
        #expect(flat.hasTextures == false)
        let textured = MaterialSpec(id: "m", baseColor: [1, 0, 0], albedoMap: "a.png")
        #expect(textured.hasTextures)
        #expect(MaterialSpec(id: "m", baseColor: [1, 0, 0], normalMap: "n.png").hasTextures)
        #expect(MaterialSpec(id: "m", baseColor: [1, 0, 0], roughnessMap: "r.png").hasTextures)
        #expect(MaterialSpec(id: "m", baseColor: [1, 0, 0], emissiveMap: "e.png").hasTextures)
    }

    @Test func texturedMaterialRoundTrips() throws {
        var spec = Self.sampleSpec()
        spec.materials[0] = MaterialSpec(
            id: "wood", baseColor: [0.4, 0.2, 0.1], roughness: 0.7, metallic: 0.2,
            emissive: [0.1, 0, 0], albedoMap: "albedo.png", normalMap: "normal.png",
            roughnessMap: "rough.png", emissiveMap: "emit.png", normalScale: 0.5)
        let back = try ObjectSculptSpec.decoded(from: spec.encoded())
        #expect(back == spec)
        #expect(back.materials[0].hasTextures)
    }

    @Test func materialDecodeDefaultsMissingScalarsAndMaps() throws {
        // Legacy material JSON lacking roughness/metallic/maps decode-defaults.
        let legacy = #"{"id":"m","baseColor":[0.2,0.3,0.4]}"#
        let mat = try JSONDecoder().decode(MaterialSpec.self, from: Data(legacy.utf8))
        #expect(mat.roughness == 0.5)
        #expect(mat.metallic == 0)
        #expect(mat.emissive == nil)
        #expect(mat.albedoMap == nil)
        #expect(mat.normalMap == nil)
        #expect(mat.roughnessMap == nil)
        #expect(mat.emissiveMap == nil)
        #expect(mat.normalScale == nil)
        #expect(mat.hasTextures == false)
    }

    // MARK: - Surface projection + landmarks

    @Test func surfaceProjectionJSONAndDefaults() throws {
        let cam = CameraPose(position: [0, 0, 5], target: [0, 0, 0])
        #expect(cam.up == [0, 1, 0])   // default up
        let projection = SurfaceProjection(targetComponent: "Body", camera: cam)
        #expect(projection.uvSet == "st")
        #expect(projection.delight == true)
        let json = try projection.json()
        #expect(json.contains("Body"))
        #expect(json.contains("st"))
    }

    @Test func surfaceAndLandmarksRoundTrip() throws {
        var spec = Self.sampleSpec()
        spec.surfaceProjection = SurfaceProjection(
            targetComponent: "Body",
            camera: CameraPose(position: [0, 1, 4], target: [0, 1, 0], up: [0, 1, 0]),
            uvSet: "st", delight: false)
        spec.landmarks = [Landmark(name: "top", component: "Body", position: [0, 2, 0])]
        let back = try ObjectSculptSpec.decoded(from: spec.encoded())
        #expect(back == spec)
        #expect(back.surfaceProjection?.delight == false)
        #expect(back.landmarks.first?.name == "top")
    }

    @Test func legacySpecDecodesWithoutSurfaceOrLandmarks() throws {
        let legacy = #"{"name":"L","objectClass":"object","root":{"name":"Root","shape":{"group":{}},"translation":[0,0,0],"rotationEulerDegrees":[0,0,0],"scale":[1,1,1],"width":1,"height":1,"depth":1,"radius":0.5,"segments":16,"children":[]}}"#
        let decoded = try ObjectSculptSpec.decoded(from: Data(legacy.utf8))
        #expect(decoded.surfaceProjection == nil)
        #expect(decoded.landmarks.isEmpty)
    }

    // MARK: - ShapeKind friendly Codable (issue #112)

    private func roundTrip(_ kind: ShapeKind) throws -> (json: String, back: ShapeKind) {
        let data = try JSONEncoder().encode(kind)
        let back = try JSONDecoder().decode(ShapeKind.self, from: data)
        return (String(decoding: data, as: UTF8.self), back)
    }

    @Test func shapeKindEncodesFriendlyTaggedForm() throws {
        let group = try roundTrip(.group)
        #expect(group.json.contains("\"kind\":\"group\""))
        #expect(group.back == .group)

        let prim = try roundTrip(.primitive(.box))
        #expect(prim.json.contains("\"kind\":\"primitive\""))
        #expect(prim.json.contains("\"primitive\":\"box\""))
        #expect(!prim.json.contains("_0"))   // the leaky synthesized key is gone
        #expect(prim.back == .primitive(.box))

        // Exercises the `.library` encode branch specifically.
        let lib = try roundTrip(.library(entryID: "prefab.rock"))
        #expect(lib.json.contains("\"kind\":\"library\""))
        #expect(lib.json.contains("\"entryID\":\"prefab.rock\""))
        #expect(lib.back == .library(entryID: "prefab.rock"))
    }

    @Test func shapeKindDecodesFriendlyForms() throws {
        func decode(_ json: String) throws -> ShapeKind {
            try JSONDecoder().decode(ShapeKind.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"kind":"group"}"#) == .group)
        #expect(try decode(#"{"kind":"primitive","primitive":"cone"}"#) == .primitive(.cone))
        #expect(try decode(#"{"kind":"library","entryID":"prefab.gear"}"#) == .library(entryID: "prefab.gear"))
    }

    @Test func shapeKindDecodesLegacyAssociatedValueForms() throws {
        func decode(_ json: String) throws -> ShapeKind {
            try JSONDecoder().decode(ShapeKind.self, from: Data(json.utf8))
        }
        // The old Swift-default coding: group/{}, primitive/{_0}, library/{entryID}.
        #expect(try decode(#"{"group":{}}"#) == .group)
        #expect(try decode(#"{"primitive":{"_0":"sphere"}}"#) == .primitive(.sphere))
        #expect(try decode(#"{"library":{"entryID":"prefab.rock"}}"#) == .library(entryID: "prefab.rock"))
    }

    @Test func shapeKindRejectsUnknownForm() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ShapeKind.self, from: Data(#"{"mystery":true}"#.utf8))
        }
    }

    // MARK: - Attachment authoring warning (issue #113)

    @Test func componentsMissingAttachmentListsFloatingGeometry() {
        let attached = ComponentNode(name: "Lid", shape: .primitive(.box), attachment: .weld)
        let floating = ComponentNode(name: "Knob", shape: .primitive(.sphere))   // no attachment
        let group = ComponentNode(name: "Slot", shape: .group)                    // exempt (no geometry)
        let root = ComponentNode(name: "Root", shape: .group, children: [attached, floating, group])
        let spec = ObjectSculptSpec(name: "Box", objectClass: .object, root: root)
        #expect(SpecValidator.componentsMissingAttachment(spec) == ["Knob"])
    }
}
