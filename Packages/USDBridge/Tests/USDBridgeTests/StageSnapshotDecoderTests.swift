import Testing
import Foundation
import USDCore
@testable import USDBridge

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    return try Data(contentsOf: try #require(url))
}

private func json(_ string: String) -> Data { Data(string.utf8) }

@Suite("StageSnapshotDecoder — valid payloads")
struct DecoderValidTests {

    @Test func decodesCarFixtureCompletely() throws {
        let stage = try StageSnapshotDecoder.decode(
            try fixtureData("car_snapshot"),
            sourceURL: URL(fileURLWithPath: "/tmp/car.usdz"))

        #expect(stage.sourceURL?.lastPathComponent == "car.usdz")
        #expect(stage.metadata.upAxis == .y)
        #expect(stage.metadata.metersPerUnit == 0.01)
        #expect(stage.metadata.defaultPrim == "Car")
        #expect(stage.metadata.customLayerData["creator"] == "fixture")

        let car = try #require(stage.prim(at: PrimPath("/Car")!))
        #expect(car.typeName == "Xform")
        #expect(car.metadata["kind"] == "assembly")
        #expect(car.variantSets == [VariantSet(name: "color", variants: ["red", "blue"], selection: "red")])
        #expect(car.children.count == 2)

        // Every wire value type decodes to the right AttributeValue case.
        #expect(car.attribute(named: "xformOp:translate")?.value == .vector([0, 0.5, 0]))
        #expect(car.attribute(named: "xformOpOrder")?.value == .stringArray(["xformOp:translate"]))
        #expect(car.attribute(named: "customFlag")?.value == .bool(true))
        #expect(car.attribute(named: "count")?.value == .int(4))
        #expect(car.attribute(named: "mass")?.value == .double(1200.5))
        #expect(car.attribute(named: "label")?.value == .string("car"))
        #expect(car.attribute(named: "purpose")?.value == .token("default"))
        #expect(car.attribute(named: "tex")?.value == .asset("textures/body.png"))
        #expect(car.attribute(named: "xf")?.value == .matrix4([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]))
        #expect(car.attribute(named: "indices")?.value == .intArray([0, 1, 2]))
        #expect(car.attribute(named: "weights")?.value == .doubleArray([0.5, 0.5]))
        #expect(car.attribute(named: "weird")?.value == .unsupported(typeName: "unsupported:matrix2d"))

        let wheel = try #require(stage.prim(at: PrimPath("/Car/Wheel")!))
        #expect(wheel.visibility == .invisible)
        let antenna = try #require(stage.prim(at: PrimPath("/Car/Antenna")!))
        #expect(!antenna.isActive)
        #expect(antenna.visibility == .inherited)
    }

    @Test func missingOptionalFieldsGetDefaults() throws {
        let stage = try StageSnapshotDecoder.decode(json(#"{"prims":[{"path":"/A"}]}"#))
        #expect(stage.metadata == StageMetadata())
        let prim = try #require(stage.prim(at: PrimPath("/A")!))
        #expect(prim.isActive && prim.visibility == .inherited && prim.typeName.isEmpty)
        #expect(stage.sourceURL == nil)
    }

    @Test func floatAliasesDecodeAsDouble() throws {
        let stage = try StageSnapshotDecoder.decode(json(
            #"{"prims":[{"path":"/A","attributes":[{"name":"f","type":"float","double":1.5},{"name":"fa","type":"float[]","doubles":[1]},{"name":"ta","type":"token[]","strings":["x"]}]}]}"#))
        let prim = stage.prim(at: PrimPath("/A")!)!
        #expect(prim.attribute(named: "f")?.value == .double(1.5))
        #expect(prim.attribute(named: "fa")?.value == .doubleArray([1]))
        #expect(prim.attribute(named: "ta")?.value == .stringArray(["x"]))
    }

    @Test func zUpAxisDecodes() throws {
        let stage = try StageSnapshotDecoder.decode(json(#"{"metadata":{"upAxis":"Z"},"prims":[]}"#))
        #expect(stage.metadata.upAxis == .z)
    }
}

@Suite("StageSnapshotDecoder — malformed payloads")
struct DecoderMalformedTests {

    private func expectMalformed(_ payload: String) {
        #expect(throws: BridgeError.self) {
            _ = try StageSnapshotDecoder.decode(json(payload))
        }
    }

    @Test func rejectsNonJSON() {
        expectMalformed("this is not json")
    }

    @Test func rejectsMissingPrimsKey() {
        expectMalformed(#"{"metadata":{}}"#)
    }

    @Test func rejectsInvalidPrimPath() {
        expectMalformed(#"{"prims":[{"path":"not-absolute"}]}"#)
    }

    @Test func rejectsUnknownVisibility() {
        expectMalformed(#"{"prims":[{"path":"/A","visibility":"sometimes"}]}"#)
    }

    @Test func rejectsUnknownUpAxis() {
        expectMalformed(#"{"metadata":{"upAxis":"X"},"prims":[]}"#)
    }

    @Test(arguments: [0.0, -1.0]) func rejectsNonPositiveMetersPerUnit(_ value: Double) {
        expectMalformed(#"{"metadata":{"metersPerUnit":\#(value)},"prims":[]}"#)
    }

    @Test func rejectsChildWithMismatchedParentPath() {
        expectMalformed(#"{"prims":[{"path":"/A","children":[{"path":"/B/C"}]}]}"#)
    }

    @Test func rejectsAttributeValueTypeMismatch() {
        // Declared bool but carries no bool payload.
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"bool","int":1}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"int"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"double"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"string"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"token"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"asset"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"int[]"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"double[]"}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"string[]"}]}]}"#)
    }

    @Test func rejectsBadVectorArity() {
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"vector","doubles":[1]}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"vector","doubles":[1,2,3,4,5]}]}]}"#)
        expectMalformed(#"{"prims":[{"path":"/A","attributes":[{"name":"x","type":"matrix4d","doubles":[1,2,3]}]}]}"#)
    }
}
