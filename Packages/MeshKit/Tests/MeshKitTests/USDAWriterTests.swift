import Testing
import Foundation
@testable import MeshKit

@Suite("USDAWriter")
struct USDAWriterTests {

    private func build(_ recipe: ModelRecipe) throws -> String {
        USDAWriter.usda(for: try RecipeEngine.execute(recipe))
    }

    @Test func headerCarriesStageMetadata() throws {
        let usda = try build(ModelRecipe(
            name: "My Crate!", upAxis: "Z", metersPerUnit: 0.01,
            parts: [RecipePart(name: "P", primitive: RecipePrimitive(type: "box"))]))
        #expect(usda.hasPrefix("#usda 1.0"))
        #expect(usda.contains("defaultPrim = \"My_Crate_\""))
        #expect(usda.contains("upAxis = \"Z\""))
        #expect(usda.contains("metersPerUnit = 0.01"))
        #expect(usda.contains("def Xform \"My_Crate_\""))
    }

    @Test func meshArraysMatchTheFlatMesh() throws {
        let recipe = ModelRecipe(name: "Box", parts: [
            RecipePart(name: "P", primitive: RecipePrimitive(type: "box"))])
        let result = try RecipeEngine.execute(recipe)
        let usda = USDAWriter.usda(for: result)
        let flat = result.parts[0].flat
        #expect(usda.contains("int[] faceVertexCounts = [\(flat.faceVertexCounts.map(String.init).joined(separator: ", "))]"))
        #expect(usda.contains("point3f[] points = ["))
        #expect(usda.contains("uniform token subdivisionScheme = \"none\""))
        // Extent of a unit box centered at origin.
        #expect(usda.contains("float3[] extent = [(-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)]"))
    }

    @Test func materialsAuthorTheRealFileShaderShape() throws {
        // Shader must be a *child* of the Material with inputs on the shader —
        // the shape MaterialBinding.resolve expects (.claude/skills/verify).
        let usda = try build(ModelRecipe(
            name: "M",
            materials: [RecipeMaterial(name: "Paint", diffuseColor: [1, 0.5, 0.25],
                                       roughness: 0.4, metallic: 0.1, opacity: 0.9)],
            parts: [RecipePart(name: "P", primitive: RecipePrimitive(type: "box"),
                               material: "Paint")]))
        #expect(usda.contains("def Material \"Paint\""))
        #expect(usda.contains("def Shader \"PreviewSurface\""))
        #expect(usda.contains("uniform token info:id = \"UsdPreviewSurface\""))
        #expect(usda.contains("color3f inputs:diffuseColor = (1, 0.5, 0.25)"))
        #expect(usda.contains("float inputs:roughness = 0.4"))
        #expect(usda.contains("float inputs:metallic = 0.1"))
        #expect(usda.contains("float inputs:opacity = 0.9"))
        #expect(usda.contains("token outputs:surface.connect = <PreviewSurface.outputs:surface>"))
        #expect(usda.contains("rel material:binding = </M/Materials/Paint>"))
        #expect(usda.contains("prepend apiSchemas = [\"MaterialBindingAPI\"]"))
        #expect(usda.contains("primvars:displayColor = [(1, 0.5, 0.25)]"))
    }

    @Test func materialSubsetsBecomeBoundGeomSubsets() throws {
        let usda = try build(ModelRecipe(
            name: "Tank",
            materials: [
                RecipeMaterial(name: "Hull", diffuseColor: [0.3, 0.4, 0.3]),
                RecipeMaterial(name: "Hatch", diffuseColor: [0.8, 0.1, 0.1]),
            ],
            parts: [RecipePart(
                name: "Body", primitive: RecipePrimitive(type: "box"), material: "Hull",
                steps: [RecipeStep(op: "assignMaterial",
                                   select: RecipeSelector(facing: [0, 1, 0]),
                                   material: "Hatch")])]))
        #expect(usda.contains("def GeomSubset \"Hatch\""))
        #expect(usda.contains("uniform token familyName = \"materialBind\""))
        #expect(usda.contains("rel material:binding = </Tank/Materials/Hatch>"))
    }

    @Test func plainSubsetsAreTaggedButUnbound() throws {
        let usda = try build(ModelRecipe(
            name: "X",
            parts: [RecipePart(
                name: "P", primitive: RecipePrimitive(type: "box"),
                steps: [RecipeStep(op: "tagSubset",
                                   select: RecipeSelector(facing: [0, 1, 0]),
                                   subset: "lid")])]))
        #expect(usda.contains("def GeomSubset \"lid\""))
        #expect(!usda.contains("</X/Materials/lid>"))
    }

    @Test func transformsAuthorXformOpsInOrder() throws {
        let usda = try build(ModelRecipe(
            name: "X",
            parts: [RecipePart(
                name: "P", primitive: RecipePrimitive(type: "box"),
                transform: RecipeTransform(translate: [1, 2, 3],
                                           rotateDegrees: [0, 45, 0],
                                           scale: [2, 2, 2]))]))
        #expect(usda.contains("double3 xformOp:translate = (1, 2, 3)"))
        #expect(usda.contains("float3 xformOp:rotateXYZ = (0, 45, 0)"))
        #expect(usda.contains("float3 xformOp:scale = (2, 2, 2)"))
        #expect(usda.contains("uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:rotateXYZ\", \"xformOp:scale\"]"))
    }

    @Test func sanitizeProducesValidUSDIdentifiers() {
        #expect(USDAWriter.sanitize("My Crate!") == "My_Crate_")
        #expect(USDAWriter.sanitize("2Fast") == "_2Fast")
        #expect(USDAWriter.sanitize("") == "Unnamed")
        #expect(USDAWriter.sanitize("ok_name3") == "ok_name3")
        #expect(USDAWriter.sanitize("héllo") == "h_llo")
    }

    @Test func numericFormattingIsCompactAndRoundTrippable() {
        #expect(USDAWriter.format(1.0) == "1")
        #expect(USDAWriter.format(-2.0) == "-2")
        #expect(USDAWriter.format(0.5) == "0.5")
        #expect(Double(USDAWriter.format(0.1 + 0.2)) == 0.1 + 0.2)
    }

    @Test func multiPartOutputContainsEveryPartOnce() throws {
        let usda = try build(ModelRecipe(name: "Snowman", parts: [
            RecipePart(name: "Base", primitive: RecipePrimitive(type: "sphere", rings: 4)),
            RecipePart(name: "Head", primitive: RecipePrimitive(type: "sphere", radius: 0.3, rings: 4)),
        ]))
        #expect(usda.components(separatedBy: "def Xform \"Base\"").count == 2)
        #expect(usda.components(separatedBy: "def Xform \"Head\"").count == 2)
        #expect(usda.components(separatedBy: "def Mesh \"Geom\"").count == 3)
    }

    @Test func bracesBalance() throws {
        let usda = try build(ModelRecipe(
            name: "B",
            materials: [RecipeMaterial(name: "M", diffuseColor: [0, 0, 0])],
            parts: [RecipePart(name: "P", primitive: RecipePrimitive(type: "cone"),
                               material: "M")]))
        #expect(usda.filter { $0 == "{" }.count == usda.filter { $0 == "}" }.count)
        #expect(usda.filter { $0 == "(" }.count == usda.filter { $0 == ")" }.count)
    }
}
