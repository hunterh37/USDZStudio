import Testing
import Foundation
@testable import MeshKit

@Suite("RecipeEngine")
struct RecipeTests {

    // MARK: - Decoding

    @Test func decodesAFullRecipeFromJSON() throws {
        let json = """
        {
          "name": "Crate",
          "upAxis": "Y",
          "metersPerUnit": 0.01,
          "materials": [{"name": "Wood", "diffuseColor": [0.6, 0.4, 0.2], "roughness": 0.9}],
          "parts": [{
            "name": "Body",
            "primitive": {"type": "box", "size": [2, 1, 1]},
            "transform": {"translate": [0, 0.5, 0]},
            "material": "Wood",
            "steps": [
              {"op": "inset", "select": {"facing": [0, 1, 0]}, "fraction": 0.3},
              {"op": "extrude", "select": {"last": true}, "distance": -0.2}
            ]
          }]
        }
        """
        let recipe = try RecipeEngine.decode(Data(json.utf8))
        #expect(recipe.name == "Crate")
        #expect(recipe.parts.count == 1)
        #expect(recipe.parts[0].steps?.count == 2)
        #expect(recipe.parts[0].steps?[0].select?.facing == [0, 1, 0])
    }

    @Test func decodeFailureIsATypedRecipeErrorWithAPath() {
        let bad = Data(#"{"name": "X", "parts": [{"primitive": {"type": "box"}}]}"#.utf8)
        do {
            _ = try RecipeEngine.decode(bad)
            Issue.record("expected decode to fail")
        } catch let error as RecipeError {
            #expect(error.message.contains("name"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func pivotDecodesAsKeywordOrPoint() throws {
        let json = """
        [{"op": "scale", "scale": [2,2,2], "pivot": "origin"},
         {"op": "scale", "scale": [2,2,2], "pivot": [1, 2, 3]}]
        """
        let steps = try JSONDecoder().decode([RecipeStep].self, from: Data(json.utf8))
        #expect(steps[0].pivot == .keyword("origin"))
        #expect(steps[1].pivot == .point([1, 2, 3]))
    }

    // MARK: - Execution happy path

    @Test func boxInsetExtrudeChainBuildsHealthyGeometry() throws {
        let recipe = ModelRecipe(
            name: "Crate",
            materials: [RecipeMaterial(name: "Wood", diffuseColor: [0.6, 0.4, 0.2])],
            parts: [RecipePart(
                name: "Body",
                primitive: RecipePrimitive(type: "box", size: [2, 1, 1]),
                material: "Wood",
                steps: [
                    RecipeStep(op: "inset",
                               select: RecipeSelector(facing: [0, 1, 0]), fraction: 0.3),
                    RecipeStep(op: "extrude",
                               select: RecipeSelector(last: true), distance: -0.2),
                ])])
        let result = try RecipeEngine.execute(recipe)
        let part = result.parts[0]
        // Box(6) → inset top (+4) → extrude inner (+4).
        #expect(part.mesh.faceCount == 14)
        #expect(MeshInvariants.violations(in: part.mesh, allowBoundaries: false).isEmpty)
        // Carved a 0.2-deep pocket: volume shrinks by pocketArea × depth.
        #expect(part.mesh.signedVolume < 2)
        #expect(part.stepReports.count == 2)
        #expect(part.stepReports[0].op == "inset" && part.stepReports[0].selectedComponents == 1)
        #expect(part.stepReports[1].deltaFaces == 4)
    }

    @Test func facingSelectorPicksExactlyTheAxisFaces() throws {
        let mesh = try Primitives.box()
        let selection = try SelectorResolver.faces(
            RecipeSelector(facing: [0, 0, 1]), in: mesh, last: nil)
        guard case .faces(let faces) = selection else { Issue.record("not faces"); return }
        #expect(faces.count == 1)
        #expect(mesh.faceNormalArea(faces.first!).z > 0)
    }

    @Test func withinRefinesFacingOnAMultiSegmentBox() throws {
        let mesh = try Primitives.box(width: 2, height: 1, depth: 1, segments: SIMD3(4, 1, 1))
        // Top faces only on the +X half.
        let selection = try SelectorResolver.faces(
            RecipeSelector(facing: [0, 1, 0],
                           within: RecipeBounds(min: [0, -1, -1], max: [2, 1, 1])),
            in: mesh, last: nil)
        guard case .faces(let faces) = selection else { Issue.record("not faces"); return }
        #expect(faces.count == 2)
        for f in faces { #expect(mesh.faceCentroid(f).x > 0) }
    }

    @Test func boundarySelectorFeedsFillHole() throws {
        let recipe = ModelRecipe(name: "Tube", parts: [RecipePart(
            name: "T",
            primitive: RecipePrimitive(type: "cylinder", radialSegments: 6, capped: false),
            steps: [
                // Two rims → two boundary loops; fillHole closes one loop per
                // call (by design), so chain two boundary-selected fills.
                RecipeStep(op: "fillHole", select: RecipeSelector(boundary: true)),
                RecipeStep(op: "fillHole", select: RecipeSelector(boundary: true)),
            ])])
        let result = try RecipeEngine.execute(recipe)
        #expect(MeshInvariants.violations(in: result.parts[0].mesh, allowBoundaries: false).isEmpty)
        #expect(result.parts[0].mesh.signedVolume > 0)
    }

    @Test func translateStepMovesSelectedFaces() throws {
        let recipe = ModelRecipe(name: "Wedge", parts: [RecipePart(
            name: "W",
            primitive: RecipePrimitive(type: "box"),
            steps: [
                RecipeStep(op: "translate",
                           select: RecipeSelector(facing: [0, 1, 0]),
                           offset: [0.5, 0, 0]),
            ])])
        let result = try RecipeEngine.execute(recipe)
        let mesh = result.parts[0].mesh
        #expect(MeshInvariants.violations(in: mesh, allowBoundaries: false).isEmpty)
        let maxX = mesh.vertexOrder.map { mesh.positions[$0]!.x }.max()!
        #expect(abs(maxX - 1.0) < 1e-12) // 0.5 half-width + 0.5 shear
    }

    @Test func assignMaterialTagsASubsetCarriedToFlatMesh() throws {
        let recipe = ModelRecipe(
            name: "Tank",
            materials: [
                RecipeMaterial(name: "Hull", diffuseColor: [0.3, 0.4, 0.3]),
                RecipeMaterial(name: "Hatch", diffuseColor: [0.8, 0.1, 0.1]),
            ],
            parts: [RecipePart(
                name: "Body",
                primitive: RecipePrimitive(type: "box"),
                material: "Hull",
                steps: [
                    RecipeStep(op: "assignMaterial",
                               select: RecipeSelector(facing: [0, 1, 0]), material: "Hatch"),
                ])])
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].flat.subsets["Hatch"]?.count == 1)
    }

    @Test func multiPartRecipeReportsTotals() throws {
        let recipe = ModelRecipe(name: "Snowman", parts: [
            RecipePart(name: "Base", primitive: RecipePrimitive(type: "sphere", rings: 4)),
            RecipePart(name: "Head",
                       primitive: RecipePrimitive(type: "sphere", radius: 0.3, rings: 4),
                       transform: RecipeTransform(translate: [0, 0.7, 0])),
            RecipePart(name: "Nose", primitive: RecipePrimitive(type: "cone", radialSegments: 6)),
        ])
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts.count == 3)
        #expect(result.totalFaces == result.parts.reduce(0) { $0 + $1.mesh.faceCount })
        #expect(result.totalTriangles > result.totalFaces) // quads count double
    }

    // MARK: - Failure diagnostics (the agent feedback loop)

    private func executionError(_ recipe: ModelRecipe) -> RecipeError? {
        do { _ = try RecipeEngine.execute(recipe); return nil }
        catch let error as RecipeError { return error }
        catch { Issue.record("wrong error type: \(error)"); return nil }
    }

    @Test func unknownOpNamesTheKnownOps() {
        let recipe = ModelRecipe(name: "X", parts: [RecipePart(
            name: "P", primitive: RecipePrimitive(type: "box"),
            steps: [RecipeStep(op: "subsurf", select: RecipeSelector(all: true))])])
        let error = executionError(recipe)
        #expect(error?.part == "P" && error?.step == 0)
        #expect(error?.message.contains("extrude") == true)
    }

    @Test func missingParamsNameTheMissingField() {
        for (step, field) in [
            (RecipeStep(op: "extrude", select: RecipeSelector(all: true)), "distance"),
            (RecipeStep(op: "inset", select: RecipeSelector(all: true)), "fraction"),
            (RecipeStep(op: "bevel", select: RecipeSelector(boundary: true)), "width"),
            (RecipeStep(op: "translate", select: RecipeSelector(all: true)), "offset"),
            (RecipeStep(op: "assignMaterial", select: RecipeSelector(all: true)), "material"),
        ] {
            let recipe = ModelRecipe(name: "X", parts: [RecipePart(
                name: "P", primitive: RecipePrimitive(type: "plane"), steps: [step])])
            #expect(executionError(recipe)?.message.contains(field) == true,
                    "op \(step.op) should name '\(field)'")
        }
    }

    @Test func opFailuresCarryPartAndStepCoordinates() {
        let recipe = ModelRecipe(name: "X", parts: [RecipePart(
            name: "Body", primitive: RecipePrimitive(type: "box"),
            steps: [
                RecipeStep(op: "inset", select: RecipeSelector(all: true), fraction: 0.2),
                RecipeStep(op: "inset", select: RecipeSelector(all: true), fraction: 7),
            ])])
        let error = executionError(recipe)
        #expect(error?.part == "Body" && error?.step == 1)
        #expect(error?.message.contains("fraction") == true)
    }

    @Test func selectorMistakesAreDiagnosed() {
        // Empty facing match.
        var recipe = ModelRecipe(name: "X", parts: [RecipePart(
            name: "P", primitive: RecipePrimitive(type: "box"),
            steps: [RecipeStep(op: "extrude",
                               select: RecipeSelector(facing: [0, 1, 0], minDot: 1.5),
                               distance: 1)])])
        #expect(executionError(recipe)?.message.contains("matched no faces") == true)

        // 'last' on the first step.
        recipe.parts[0].steps = [
            RecipeStep(op: "extrude", select: RecipeSelector(last: true), distance: 1)]
        #expect(executionError(recipe)?.message.contains("previous step") == true)

        // Two sources at once.
        recipe.parts[0].steps = [
            RecipeStep(op: "extrude",
                       select: RecipeSelector(all: true, faces: [0]), distance: 1)]
        #expect(executionError(recipe)?.message.contains("exactly one source") == true)

        // Face index out of range.
        recipe.parts[0].steps = [
            RecipeStep(op: "extrude", select: RecipeSelector(faces: [99]), distance: 1)]
        #expect(executionError(recipe)?.message.contains("out of range") == true)

        // Missing selector entirely.
        recipe.parts[0].steps = [RecipeStep(op: "extrude", distance: 1)]
        #expect(executionError(recipe)?.message.contains("select") == true)
    }

    @Test func recipeLevelValidation() {
        #expect(executionError(ModelRecipe(name: "", parts: []))?.message.contains("name") == true)
        #expect(executionError(ModelRecipe(name: "X", parts: []))?.message.contains("no parts") == true)
        #expect(executionError(ModelRecipe(name: "X", upAxis: "Q",
                                           parts: [RecipePart(name: "P", primitive: RecipePrimitive(type: "box"))]))?
            .message.contains("upAxis") == true)
        // Unknown material reference.
        let badMaterial = ModelRecipe(name: "X", parts: [
            RecipePart(name: "P", primitive: RecipePrimitive(type: "box"), material: "Nope")])
        #expect(executionError(badMaterial)?.message.contains("Nope") == true)
        // Bad diffuse color.
        let badColor = ModelRecipe(
            name: "X",
            materials: [RecipeMaterial(name: "M", diffuseColor: [2, 0, 0])],
            parts: [RecipePart(name: "P", primitive: RecipePrimitive(type: "box"))])
        #expect(executionError(badColor)?.message.contains("diffuseColor") == true)
        // Duplicate part names after sanitizing.
        let dupe = ModelRecipe(name: "X", parts: [
            RecipePart(name: "A B", primitive: RecipePrimitive(type: "box")),
            RecipePart(name: "A_B", primitive: RecipePrimitive(type: "box"))])
        #expect(executionError(dupe)?.message.contains("duplicate") == true)
        // Unknown primitive.
        let badPrim = ModelRecipe(name: "X", parts: [
            RecipePart(name: "P", primitive: RecipePrimitive(type: "torus"))])
        #expect(executionError(badPrim)?.message.contains("torus") == true)
    }

    @Test func mergeRequiresExactlyOneMode() {
        let both = ModelRecipe(name: "X", parts: [RecipePart(
            name: "P", primitive: RecipePrimitive(type: "box"),
            steps: [RecipeStep(op: "merge", select: RecipeSelector(vertices: [0, 1]),
                               threshold: 0.1, targetVertex: 0)])])
        #expect(executionError(both)?.message.contains("not both") == true)
        let neither = ModelRecipe(name: "X", parts: [RecipePart(
            name: "P", primitive: RecipePrimitive(type: "box"),
            steps: [RecipeStep(op: "merge", select: RecipeSelector(vertices: [0, 1]))])])
        #expect(executionError(neither)?.message.contains("threshold") == true)
    }

    @Test func recipeRoundTripsThroughCodable() throws {
        let recipe = ModelRecipe(
            name: "RT",
            materials: [RecipeMaterial(name: "M", diffuseColor: [0.1, 0.2, 0.3])],
            parts: [RecipePart(
                name: "P",
                primitive: RecipePrimitive(type: "cylinder", radius: 0.4, radialSegments: 6),
                transform: RecipeTransform(translate: [1, 0, 0], rotateDegrees: [0, 45, 0]),
                material: "M",
                steps: [RecipeStep(op: "bevel", select: RecipeSelector(edges: [[0, 1]]),
                                   width: 0.1, pivot: .point([0, 1, 0]))])])
        let data = try JSONEncoder().encode(recipe)
        #expect(try RecipeEngine.decode(data) == recipe)
    }
}
