import Testing
import Foundation
@testable import USDCore

@Suite("USDASerializer")
struct USDASerializerTests {

    private func makeStage(_ rootPrims: [Prim], metadata: StageMetadata = StageMetadata(defaultPrim: "Root")) -> StageSnapshot {
        StageSnapshot(metadata: metadata, rootPrims: rootPrims)
    }

    // MARK: - Layer header

    @Test func serializesHeaderMetadata() {
        let stage = makeStage([], metadata: StageMetadata(
            upAxis: .z, metersPerUnit: 0.01, defaultPrim: "Root",
            customLayerData: ["b": "2", "a": "1"]))
        let usda = USDASerializer.serialize(stage)
        #expect(usda.hasPrefix("#usda 1.0\n(\n"))
        #expect(usda.contains("defaultPrim = \"Root\""))
        #expect(usda.contains("metersPerUnit = 0.01"))
        #expect(usda.contains("upAxis = \"Z\""))
        // customLayerData keys sorted for determinism.
        let aIndex = usda.range(of: "string a = \"1\"")!.lowerBound
        let bIndex = usda.range(of: "string b = \"2\"")!.lowerBound
        #expect(aIndex < bIndex)
    }

    @Test func omitsAbsentDefaultPrimAndEmptyCustomData() {
        let usda = USDASerializer.serialize(makeStage([], metadata: StageMetadata()))
        #expect(!usda.contains("defaultPrim"))
        #expect(!usda.contains("customLayerData"))
        #expect(usda.contains("metersPerUnit = 1\n"))
    }

    // MARK: - Prim structure

    @Test func serializesPrimTreeWithTypesAndFlags() {
        var root = Prim(path: PrimPath("/Root")!, typeName: "Xform")
        var hidden = Prim(path: PrimPath("/Root/Hidden")!, typeName: "Mesh")
        hidden.visibility = .invisible
        var disabled = Prim(path: PrimPath("/Root/Disabled")!)
        disabled.isActive = false
        root.children = [hidden, disabled]

        let usda = USDASerializer.serialize(makeStage([root]))
        #expect(usda.contains("def Xform \"Root\"\n{"))
        #expect(usda.contains("def Mesh \"Hidden\""))
        #expect(usda.contains("token visibility = \"invisible\""))
        #expect(usda.contains("def \"Disabled\" (\n"))      // typeless prim
        #expect(usda.contains("active = false"))
    }

    @Test func serializesMetadataAsCustomData() {
        var prim = Prim(path: PrimPath("/M")!, typeName: "Mesh")
        prim.metadata = ["material:binding": "Red", "src": "orig"]
        let usda = USDASerializer.serialize(makeStage([prim]))
        #expect(usda.contains("custom string[] dicyanin:metadata = [\"material:binding=Red\", \"src=orig\"]"))
    }

    @Test func deterministicOutput() {
        var prim = Prim(path: PrimPath("/Root")!, typeName: "Xform")
        prim.metadata = ["z": "1", "a": "2"]
        let stage = makeStage([prim], metadata: StageMetadata(customLayerData: ["k2": "b", "k1": "a"]))
        #expect(USDASerializer.serialize(stage) == USDASerializer.serialize(stage))
    }

    // MARK: - Attribute declarations

    private func declaration(_ name: String, _ value: AttributeValue) -> String? {
        USDASerializer.declaration(for: Attribute(name: name, value: value))
    }

    @Test func declaresScalarTypes() {
        #expect(declaration("doubleSided", .bool(true)) == "bool doubleSided = true")
        #expect(declaration("count", .int(7)) == "int count = 7")
        #expect(declaration("weight", .double(0.5)) == "double weight = 0.5")
        #expect(declaration("inputs:metallic", .double(0.25)) == "float inputs:metallic = 0.25")
        #expect(declaration("label", .string("hi \"there\"\nline")) == "string label = \"hi \\\"there\\\"\\nline\"")
        #expect(declaration("kind", .token("component")) == "token kind = \"component\"")
        #expect(declaration("file", .asset("tex/albedo.png")) == "asset file = @tex/albedo.png@")
    }

    @Test func declaresVectorsWithColorInference() {
        #expect(declaration("inputs:diffuseColor", .vector([1, 0, 0])) == "color3f inputs:diffuseColor = (1, 0, 0)")
        #expect(declaration("extent", .vector([1, 2])) == "double2 extent = (1, 2)")
        #expect(declaration("rotation", .vector([0, 0, 0, 1])) == "double4 rotation = (0, 0, 0, 1)")
        #expect(declaration("bad", .vector([1])) == nil)
        #expect(declaration("bad", .vector([1, 2, 3, 4, 5])) == nil)
    }

    @Test func declaresMatrixAndArrays() {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        #expect(declaration("xformOp:transform", .matrix4(identity))
            == "matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) )")
        #expect(declaration("bad", .matrix4([1, 2])) == nil)
        #expect(declaration("faceVertexIndices", .intArray([0, 1, 2])) == "int[] faceVertexIndices = [0, 1, 2]")
        #expect(declaration("weights", .doubleArray([0.5, 1])) == "double[] weights = [0.5, 1]")
        #expect(declaration("tags", .stringArray(["a", "b"])) == "string[] tags = [\"a\", \"b\"]")
        #expect(declaration("weird", .unsupported(typeName: "quatf")) == nil)
    }

    @Test func declaresSchemaTypedGeometryArrays() {
        #expect(declaration("points", .doubleArray([0, 0, 0, 1, 0, 0]))
            == "point3f[] points = [(0, 0, 0), (1, 0, 0)]")
        #expect(declaration("normals", .doubleArray([0, 0, 1]))
            == "normal3f[] normals = [(0, 0, 1)]")
        #expect(declaration("primvars:st", .doubleArray([0, 0, 1, 1]))
            == "texCoord2f[] primvars:st = [(0, 0), (1, 1)]")
        // Mis-shaped flats are refused, not mangled.
        #expect(declaration("points", .doubleArray([0, 0])) == nil)
    }

    @Test func unsupportedAttributeBecomesComment() {
        var prim = Prim(path: PrimPath("/P")!, typeName: "Mesh")
        prim.attributes = [Attribute(name: "exotic", value: .unsupported(typeName: "quath[]"))]
        let usda = USDASerializer.serialize(makeStage([prim]))
        #expect(usda.contains("# unsupported attribute \"exotic\" (quath[]) omitted"))
    }

    @Test func transformOpEmitsXformOpOrder() {
        var prim = Prim(path: PrimPath("/X")!, typeName: "Xform")
        prim.attributes = [Attribute(name: "xformOp:transform", value: .matrix4([Double](repeating: 0, count: 16)))]
        let usda = USDASerializer.serialize(makeStage([prim]))
        #expect(usda.contains("uniform token[] xformOpOrder = [\"xformOp:transform\"]"))
    }

    /// Regression: a prim loaded with a *stored* `xformOpOrder` must serialize
    /// to a single, correctly-typed `uniform token[] xformOpOrder` — never a
    /// second `string[]` copy. The duplicate made USD reject the layer on
    /// reopen and broke `render_views` for every transformed model.
    @Test func storedXformOpOrderDoesNotDuplicate() {
        var prim = Prim(path: PrimPath("/X")!, typeName: "Xform")
        prim.attributes = [
            Attribute(name: "xformOp:transform", value: .matrix4([Double](repeating: 0, count: 16))),
            // As loaded from a file that already carried the op order.
            Attribute(name: "xformOpOrder", value: .tokenArray(["xformOp:transform"]), isUniform: true),
        ]
        let usda = USDASerializer.serialize(makeStage([prim]))
        let occurrences = usda.components(separatedBy: "xformOpOrder").count - 1
        #expect(occurrences == 1)
        #expect(usda.contains("uniform token[] xformOpOrder = [\"xformOp:transform\"]"))
        #expect(!usda.contains("string[] xformOpOrder"))
    }

    /// A non-transform xform op (e.g. `rotateXYZ`) drives the regenerated order.
    @Test func nonTransformXformOpDrivesOrder() {
        var prim = Prim(path: PrimPath("/X")!, typeName: "Xform")
        prim.attributes = [
            Attribute(name: "xformOp:rotateXYZ", value: .vector([0, -32, 0])),
            Attribute(name: "xformOpOrder", value: .tokenArray(["xformOp:rotateXYZ"]), isUniform: true),
        ]
        let usda = USDASerializer.serialize(makeStage([prim]))
        #expect(usda.contains("uniform token[] xformOpOrder = [\"xformOp:rotateXYZ\"]"))
        #expect((usda.components(separatedBy: "xformOpOrder").count - 1) == 1)
    }

    @Test func numberFormattingIsCompact() {
        #expect(USDASerializer.number(1.0) == "1")
        #expect(USDASerializer.number(-2.0) == "-2")
        #expect(USDASerializer.number(0.25) == "0.25")
        #expect(USDASerializer.number(1e16) == "1e+16")
    }
}
