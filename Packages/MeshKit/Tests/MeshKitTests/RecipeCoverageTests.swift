import Testing
import Foundation
@testable import MeshKit

/// Closes the coverage gaps the main recipe suites leave: every diagnostic
/// branch, every op route through the engine, and the small utility surfaces.
@Suite("Recipe coverage closure")
struct RecipeCoverageTests {

    private func part(_ steps: [RecipeStep],
                      primitive: RecipePrimitive = RecipePrimitive(type: "box"),
                      materials: [RecipeMaterial]? = nil) -> ModelRecipe {
        ModelRecipe(name: "X", materials: materials,
                    parts: [RecipePart(name: "P", primitive: primitive, steps: steps)])
    }

    private func error(_ recipe: ModelRecipe) -> RecipeError? {
        do { _ = try RecipeEngine.execute(recipe); return nil }
        catch let e as RecipeError { return e }
        catch { Issue.record("wrong error type: \(error)"); return nil }
    }

    // MARK: - RecipeError formatting

    @Test func errorDescriptionsCarryCoordinates() {
        #expect(RecipeError(part: "P", step: 3, message: "boom").description
                == "part 'P' step 3: boom")
        #expect(RecipeError(part: "P", message: "boom").description == "part 'P': boom")
        #expect(RecipeError(message: "boom").description == "recipe: boom")
    }

    // MARK: - Recipe-level validation branches

    @Test func nonPositiveMetersPerUnitIsRejected() {
        var recipe = part([])
        recipe.metersPerUnit = 0
        #expect(error(recipe)?.message.contains("metersPerUnit") == true)
    }

    @Test func totalsSumAcrossParts() throws {
        let result = try RecipeEngine.execute(ModelRecipe(name: "X", parts: [
            RecipePart(name: "A", primitive: RecipePrimitive(type: "box")),
            RecipePart(name: "B", primitive: RecipePrimitive(type: "cone", radialSegments: 4)),
        ]))
        #expect(result.totalVertices == 8 + 5)
        #expect(result.totalFaces == 6 + 5)
    }

    // MARK: - Engine op routes not exercised elsewhere

    @Test func extrudeAlongExplicitAxis() throws {
        let result = try RecipeEngine.execute(part([
            RecipeStep(op: "extrude", select: RecipeSelector(facing: [0, 1, 0]),
                       distance: 0.5, direction: [0, 1, 1]),
        ]))
        #expect(MeshInvariants.violations(in: result.parts[0].mesh).isEmpty)
    }

    @Test func bevelRouteWithExplicitEdgePair() throws {
        // Vertex indices 0 and 1 share an edge on the generated unit box.
        let result = try RecipeEngine.execute(part([
            RecipeStep(op: "bevel", select: RecipeSelector(edges: [[0, 1]]), width: 0.1),
        ]))
        #expect(result.parts[0].stepReports[0].op == "bevel")
        #expect(result.parts[0].mesh.faceCount == 7)
    }

    @Test func mergeRouteToTargetVertex() throws {
        // Collapse one edge of a lone quad → a healthy triangle.
        let recipe = part([
            RecipeStep(op: "merge", select: RecipeSelector(vertices: [3]), targetVertex: 2),
        ], primitive: RecipePrimitive(type: "plane"))
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].mesh.faceCount == 1)
        #expect(result.parts[0].mesh.vertexCount == 3)
    }

    @Test func mergeRouteByDistance() throws {
        let recipe = part([
            RecipeStep(op: "merge", select: RecipeSelector(vertices: [2, 3]), threshold: 10),
        ], primitive: RecipePrimitive(type: "plane"))
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].mesh.faceCount == 1)
    }

    @Test func deleteRouteRemovesFaces() throws {
        let recipe = part([
            RecipeStep(op: "delete", select: RecipeSelector(faces: [0])),
        ], primitive: RecipePrimitive(type: "plane", segments: [2, 1]))
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].mesh.faceCount == 1)
    }

    @Test func rotateAndScaleAndCombinedTransformRoutes() throws {
        let result = try RecipeEngine.execute(part([
            RecipeStep(op: "rotate", select: RecipeSelector(all: true),
                       rotateDegrees: [0, 45, 0]),
            RecipeStep(op: "scale", select: RecipeSelector(all: true), scale: [2, 1, 1]),
            RecipeStep(op: "transform", select: RecipeSelector(all: true),
                       offset: [0, 1, 0], rotateDegrees: [0, 0, 10], scale: [1, 1, 2]),
        ]))
        #expect(MeshInvariants.violations(in: result.parts[0].mesh).isEmpty)
        #expect(result.parts[0].stepReports.count == 3)
    }

    // MARK: - Step-level diagnostic branches

    @Test func stepDiagnosticsNameTheProblem() {
        let materials = [RecipeMaterial(name: "M", diffuseColor: [0, 0, 0])]
        for (recipe, needle) in [
            // rotate/scale/transform param requirements
            (part([RecipeStep(op: "rotate", select: RecipeSelector(all: true))]), "rotateDegrees"),
            (part([RecipeStep(op: "scale", select: RecipeSelector(all: true))]), "scale"),
            (part([RecipeStep(op: "transform", select: RecipeSelector(all: true))]), "at least one"),
            // vector arity and pivot keywords
            (part([RecipeStep(op: "translate", select: RecipeSelector(all: true),
                              offset: [1, 2])]), "[x, y, z]"),
            (part([RecipeStep(op: "scale", select: RecipeSelector(all: true),
                              scale: [2, 2, 2], pivot: .keyword("center"))]), "unknown pivot"),
            // subset tagging
            (part([RecipeStep(op: "assignMaterial", select: RecipeSelector(all: true),
                              material: "Nope")], materials: materials), "unknown material 'Nope'"),
            (part([RecipeStep(op: "tagSubset", select: RecipeSelector(all: true),
                              subset: "")]), "tagSubset requires"),
        ] {
            #expect(error(recipe)?.message.contains(needle) == true,
                    "expected diagnostic containing '\(needle)'")
        }
    }

    @Test func pivotKeywordsRoute() throws {
        let result = try RecipeEngine.execute(part([
            RecipeStep(op: "scale", select: RecipeSelector(all: true), scale: [2, 2, 2],
                       pivot: .keyword("origin")),
            RecipeStep(op: "scale", select: RecipeSelector(all: true), scale: [0.5, 0.5, 0.5],
                       pivot: .keyword("selectionCentroid")),
            RecipeStep(op: "translate", select: RecipeSelector(all: true), offset: [1, 0, 0],
                       pivot: .point([0, 0, 0])),
        ]))
        #expect(result.parts[0].stepReports.count == 3)
    }

    // MARK: - Primitive-spec branches

    @Test func primitiveParameterErrorsAreWrapped() {
        let zeroWidth = part([], primitive: RecipePrimitive(type: "box", size: [0, 1, 1]))
        #expect(error(zeroWidth)?.message.contains("width must be > 0") == true)
        let badArity = part([], primitive: RecipePrimitive(type: "box", segments: [1, 2]))
        #expect(error(badArity)?.message.contains("'segments' must have 3 values") == true)
        let badSize = part([], primitive: RecipePrimitive(type: "plane", size: [1, 2, 3]))
        #expect(error(badSize)?.message.contains("'size' must have 2 values") == true)
    }

    // MARK: - Decode branches

    @Test func corruptJSONReportsDataCorruption() {
        do {
            _ = try RecipeEngine.decode(Data("{nope".utf8))
            Issue.record("expected decode failure")
        } catch let e as RecipeError {
            #expect(e.message.contains("invalid recipe JSON"))
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func typeMismatchNamesThePath() {
        let bad = #"{"name": "X", "parts": [{"name": 7, "primitive": {"type": "box"}}]}"#
        do {
            _ = try RecipeEngine.decode(Data(bad.utf8))
            Issue.record("expected decode failure")
        } catch let e as RecipeError {
            #expect(e.message.contains("parts") || e.message.contains("name"))
        } catch { Issue.record("wrong error type: \(error)") }
    }

    // MARK: - Selector branches

    @Test func selectorKindMismatchesAreNamed() {
        // Face op given vertices.
        let facesWanted = part([
            RecipeStep(op: "extrude", select: RecipeSelector(vertices: [0]), distance: 1)])
        #expect(error(facesWanted)?.message.contains("needs a face selection") == true)
        // Edge op given faces.
        let edgesWanted = part([
            RecipeStep(op: "bevel", select: RecipeSelector(faces: [0]), width: 0.1)])
        #expect(error(edgesWanted)?.message.contains("needs an edge selection") == true)
    }

    @Test func vertexOpsAcceptFaceSelections() throws {
        // merge over a face selection takes the face's vertex set.
        let recipe = part([
            RecipeStep(op: "merge", select: RecipeSelector(faces: [0]), threshold: 10),
        ], primitive: RecipePrimitive(type: "plane", segments: [2, 1]))
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].mesh.faceCount <= 2)
    }

    @Test func selectorEdgeCasesAreDiagnosed() {
        for (selector, needle) in [
            (RecipeSelector(boundary: true), "mesh is closed"),          // closed box
            (RecipeSelector(edges: [[0]]), "[a, b] vertex-index pair"),
            (RecipeSelector(edges: [[0, 6]]), "no edge between"),        // body diagonal
            (RecipeSelector(edges: [[0, 99]]), "out of range"),
            (RecipeSelector(vertices: [99]), "out of range"),
            (RecipeSelector(facing: [0, 1]), "'facing' must be [x, y, z]"),
            (RecipeSelector(facing: [0, 0, 0]), "zero-length"),
            // A false boolean flag is "no source given", not an empty selection.
            (RecipeSelector(boundary: false), "exactly one source"),
            (RecipeSelector(within: RecipeBounds(min: [0], max: [1])), "min/max as [x, y, z]"),
        ] {
            let step = RecipeStep(op: "delete", select: selector)
            #expect(error(part([step]))?.message.contains(needle) == true,
                    "expected '\(needle)' for \(selector)")
        }
    }

    @Test func withinAloneSelectsByCentroid() throws {
        // Standalone within: faces of a 2-face plane on the +X half only.
        let recipe = part([
            RecipeStep(op: "delete",
                       select: RecipeSelector(within: RecipeBounds(min: [0, -1, -1],
                                                                   max: [1, 1, 1]))),
        ], primitive: RecipePrimitive(type: "plane", segments: [2, 1]))
        let result = try RecipeEngine.execute(recipe)
        #expect(result.parts[0].mesh.faceCount == 1)
        #expect(result.parts[0].mesh.faceCentroid(result.parts[0].mesh.faceOrder[0]).x < 0)
    }

    // MARK: - Matrix3 utility surface

    @Test func matrix3Equality() {
        let identity = Matrix3(rows: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)))
        let rotated = TransformComponents.rotationMatrixXYZ(degrees: SIMD3(0, 90, 0))
        #expect(identity == identity)
        #expect(!(identity == rotated))
        #expect(identity * rotated == rotated)
    }
}
