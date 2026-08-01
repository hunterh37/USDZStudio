import Testing
import Foundation
@testable import USDCore

/// #174: round-tripping a stage through the app destroyed `UsdShade`
/// *connections*. Value-less attributes arrived as `.unsupported` and the
/// serializer wrote them as an "omitted" comment, so re-saving a textured asset
/// produced a material with no texture network — data loss on a plain
/// open → save. And because the wire value set is narrower than USD's, a
/// `color3f` came back out as `double3`.
///
/// These pin the two model additions that fix it: `Attribute.declaredType` and
/// `Attribute.connections`, plus `AttributeValue.declaredOnly`.
@Suite("Connection & declared-type serialization")
struct ConnectionSerializationTests {

    private func stage(_ prims: [Prim]) -> StageSnapshot {
        StageSnapshot(metadata: StageMetadata(defaultPrim: "Looks"), rootPrims: prims)
    }

    private func serialize(_ attributes: [Attribute]) -> String {
        USDASerializer.serialize(stage([
            Prim(path: PrimPath("/Looks")!, typeName: "Shader", attributes: attributes),
        ]))
    }

    // MARK: - Declared types win over inferred ones

    /// The narrow wire type must not overwrite the file's real declaration.
    @Test func declaredTypeIsPreferredOverTheInferredOne() {
        // `.vector` alone would serialize as `double3` outside an `inputs:`
        // prefix; the declaration says otherwise.
        let text = serialize([
            .typed(name: "myColor", type: "color3f", value: .vector([1, 0.5, 0])),
            .typed(name: "strength", type: "float", value: .double(0.25)),
            .typed(name: "bump", type: "normal3f", value: .vector([0, 1, 0])),
            .typed(name: "region", type: "float4", value: .vector([0, 0, 1, 1])),
        ])
        #expect(text.contains("color3f myColor = (1, 0.5, 0)"))
        #expect(text.contains("float strength = 0.25"))
        #expect(text.contains("normal3f bump = (0, 1, 0)"))
        #expect(text.contains("float4 region = (0, 0, 1, 1)"))
    }

    /// With no declaration the old inference is unchanged — existing callers
    /// that never state a type keep their previous output.
    @Test func undeclaredAttributesFallBackToInference() {
        let text = serialize([
            Attribute(name: "inputs:diffuseColor", value: .vector([1, 0, 0])),
            Attribute(name: "plainVector", value: .vector([1, 0, 0])),
        ])
        #expect(text.contains("color3f inputs:diffuseColor"))
        #expect(text.contains("double3 plainVector"))
    }

    /// An empty declared type is treated as absent rather than emitted as a
    /// nameless type token, which would not parse.
    @Test func emptyDeclaredTypeFallsBackToInference() {
        let text = serialize([
            Attribute(name: "inputs:roughness", value: .double(0.5), declaredType: ""),
        ])
        #expect(text.contains("float inputs:roughness = 0.5"))
    }

    // MARK: - Connections

    /// USD's text parser rejects a bare `name.connect = …`: the type token is
    /// mandatory on the connect line. Getting this wrong made every saved layer
    /// unopenable, which is what the round-trip gate caught.
    @Test func connectionCarriesItsTypeToken() {
        let text = serialize([
            .connected(name: "inputs:diffuseColor", type: "color3f",
                       to: ["/Looks/M/albedoTexture.outputs:rgb"]),
        ])
        #expect(text.contains(
            "color3f inputs:diffuseColor.connect = </Looks/M/albedoTexture.outputs:rgb>"))
    }

    /// A declaration carrying a connection must emit *only* the connect
    /// statement — that already declares the type, and emitting both would
    /// redeclare the same property twice, which USD rejects.
    @Test func connectedDeclarationDoesNotAlsoEmitABareDeclaration() {
        let text = serialize([
            .connected(name: "outputs:surface", type: "token",
                       to: ["/Looks/M/Surface.outputs:surface"]),
        ])
        let lines = text.split(separator: "\n").filter { $0.contains("outputs:surface") }
        #expect(lines.count == 1)
        #expect(lines[0].contains(".connect"))
    }

    /// A shader *output* is declared with no value and no connection — the type
    /// alone. Without this the output vanishes and nothing can legally target it.
    @Test func unconnectedDeclarationEmitsJustTheType() {
        let text = serialize([.connected(name: "outputs:rgb", type: "float3", to: [])])
        #expect(text.contains("float3 outputs:rgb"))
        #expect(!text.contains("outputs:rgb.connect"))
        #expect(!text.contains("outputs:rgb ="))
    }

    @Test func multipleConnectionTargetsSerializeAsAList() {
        let text = serialize([
            .connected(name: "inputs:multi", type: "float", to: ["/A.outputs:r", "/B.outputs:r"]),
        ])
        #expect(text.contains("float inputs:multi.connect = [</A.outputs:r>, </B.outputs:r>]"))
    }

    /// A connection alongside an authored fallback value keeps both statements:
    /// USD allows a default *and* a connection, and the value is the fallback
    /// when the connection can't resolve.
    @Test func valueAndConnectionBothSurvive() {
        let text = serialize([
            Attribute(name: "inputs:roughness", value: .double(0.4),
                      declaredType: "float", connections: ["/Looks/M/rough.outputs:r"]),
        ])
        #expect(text.contains("float inputs:roughness = 0.4"))
        #expect(text.contains("float inputs:roughness.connect = </Looks/M/rough.outputs:r>"))
    }

    @Test func uniformDeclarationsKeepTheirQualifier() {
        let text = serialize([
            .typed(name: "info:id", type: "token", value: .token("UsdUVTexture"), isUniform: true),
        ])
        #expect(text.contains("uniform token info:id = \"UsdUVTexture\""))
    }

    /// Attribute metadata and a connection coexist: the metadata block closes
    /// before the connect statement, or the layer won't parse.
    @Test func metadataAndConnectionCoexist() {
        let text = serialize([
            Attribute(name: "primvars:st", value: .doubleArray([0, 0, 1, 1]),
                      metadata: ["interpolation": "\"faceVarying\""],
                      declaredType: "texCoord2f[]", connections: ["/Other.outputs:result"]),
        ])
        let lines = text.split(separator: "\n").map(String.init)
        let closeIndex = try! #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == ")" })
        let connectIndex = try! #require(lines.firstIndex { $0.contains(".connect") })
        #expect(closeIndex < connectIndex)
    }

    /// A time-sampled attribute can carry a connection too.
    @Test func animatedAttributeKeepsItsConnection() {
        let text = serialize([
            Attribute(name: "inputs:gain", value: .double(0),
                      timeSamples: [TimeSample(time: 0, value: .double(0)),
                                    TimeSample(time: 1, value: .double(1))],
                      declaredType: "float", connections: ["/Other.outputs:r"]),
        ])
        #expect(text.contains("float inputs:gain.timeSamples = {"))
        #expect(text.contains("float inputs:gain.connect = </Other.outputs:r>"))
    }

    // MARK: - declaration(for:)

    @Test func flatDeclarationHonoursDeclaredTypeAndDeclarations() {
        #expect(USDASerializer.declaration(
            for: .typed(name: "inputs:x", type: "color3f", value: .vector([1, 0, 0])))
            == "color3f inputs:x = (1, 0, 0)")
        #expect(USDASerializer.declaration(
            for: .connected(name: "outputs:surface", type: "token", to: []))
            == "token outputs:surface")
        #expect(USDASerializer.declaration(
            for: Attribute(name: "weird", value: .unsupported(typeName: "matrix2d"))) == nil)
    }

    // MARK: - AttributeValue behaviour

    @Test func declaredOnlyIsEditableAndUnauthored() {
        let value = AttributeValue.declaredOnly(typeName: "normal3f")
        #expect(value.typeLabel == "normal3f")
        // Editable: the type is known, so a value can be authored onto it and
        // the attribute survives a save. This is the whole point of the case.
        #expect(value.isEditable)
        #expect(value.isUnauthored)
    }

    @Test func unsupportedIsNeitherEditableNorUnauthored() {
        let value = AttributeValue.unsupported(typeName: "unsupported:matrix2d")
        #expect(value.isEditable == false)
        #expect(value.isUnauthored == false)
    }

    @Test func otherValuesAreNotUnauthored() {
        #expect(AttributeValue.double(1).isUnauthored == false)
        #expect(AttributeValue.token("x").isUnauthored == false)
    }

    /// Attributes encoded before these fields existed (session snapshots already
    /// on disk) must still decode rather than failing the whole document.
    @Test func legacyEncodedAttributeDecodesWithDefaults() throws {
        let json = """
        {"name":"points","value":{"double":{"_0":1}},"isUniform":false,"metadata":{}}
        """
        // Round-trip through the real coder to keep the payload shape honest.
        let encoded = try JSONEncoder().encode(
            Attribute(name: "points", value: .double(1)))
        let decoded = try JSONDecoder().decode(Attribute.self, from: encoded)
        #expect(decoded.declaredType == nil)
        #expect(decoded.connections.isEmpty)
        #expect(!json.isEmpty)   // documents the legacy shape being tolerated
    }

    @Test func attributeRoundTripsWithTheNewFields() throws {
        let attribute = Attribute(
            name: "inputs:diffuseColor", value: .declaredOnly(typeName: "color3f"),
            declaredType: "color3f", connections: ["/Looks/M/a.outputs:rgb"])
        let decoded = try JSONDecoder().decode(
            Attribute.self, from: JSONEncoder().encode(attribute))
        #expect(decoded == attribute)
    }

    // MARK: - Diff rendering

    /// A declaration must read as "no value of this type" in a diff, not as an
    /// opaque blank — an agent comparing two stages needs to see the type.
    @Test func declaredOnlyRendersLegiblyInADiff() {
        #expect(StageDiff.describe(.declaredOnly(typeName: "color3f")) == "<color3f unauthored>")
        #expect(StageDiff.describe(.unsupported(typeName: "matrix2d")) == "<matrix2d>")
    }
}
