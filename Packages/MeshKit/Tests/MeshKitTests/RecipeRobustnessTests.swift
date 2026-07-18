import Testing
import Foundation
@testable import MeshKit

/// Robustness coverage for the recipe pipeline added in the agent-modeling
/// commit: name-collision validation (materials/subsets after USD sanitizing)
/// and selector edge cases that previously produced misleading errors.
@Suite("Recipe robustness")
struct RecipeRobustnessTests {

    private func box(named name: String = "p", material: String? = nil,
                     steps: [RecipeStep]? = nil) -> RecipePart {
        RecipePart(name: name, primitive: RecipePrimitive(type: "box"),
                   material: material, steps: steps)
    }

    private func expectRecipeError(_ recipe: ModelRecipe, containing needle: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try RecipeEngine.execute(recipe)
            Issue.record("expected RecipeError containing '\(needle)'",
                         sourceLocation: sourceLocation)
        } catch let error as RecipeError {
            #expect(error.message.contains(needle),
                    "got: \(error.description)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("wrong error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Material name collisions (previously crashed USDAWriter)

    @Test func exactDuplicateMaterialNamesAreRejected() {
        let recipe = ModelRecipe(
            name: "m",
            materials: [RecipeMaterial(name: "paint", diffuseColor: [1, 0, 0]),
                        RecipeMaterial(name: "paint", diffuseColor: [0, 1, 0])],
            parts: [box(material: "paint")])
        expectRecipeError(recipe, containing: "duplicate material")
    }

    @Test func sanitizeCollidingMaterialNamesAreRejected() {
        // "arm-1" and "arm_1" both sanitize to the USD identifier "arm_1";
        // unchecked, USDAWriter's uniqueKeysWithValues dictionary would trap.
        let recipe = ModelRecipe(
            name: "m",
            materials: [RecipeMaterial(name: "arm-1", diffuseColor: [1, 0, 0]),
                        RecipeMaterial(name: "arm_1", diffuseColor: [0, 1, 0])],
            parts: [box(material: "arm-1")])
        expectRecipeError(recipe, containing: "arm_1")
    }

    // MARK: - Subset prim-name collisions (previously wrote duplicate prims)

    @Test func collidingSubsetNamesGetUniquePrimNames() throws {
        // "top face" and "top_face" sanitize to the same prim name; the writer
        // must uniquify so the .usda has no duplicate sibling prims.
        let steps = [
            RecipeStep(op: "tagSubset", select: RecipeSelector(facing: [0, 1, 0]),
                       subset: "top face"),
            RecipeStep(op: "tagSubset", select: RecipeSelector(facing: [0, -1, 0]),
                       subset: "top_face"),
        ]
        let result = try RecipeEngine.execute(
            ModelRecipe(name: "m", parts: [box(steps: steps)]))
        let usda = USDAWriter.usda(for: result)
        let plain = usda.components(separatedBy: "def GeomSubset \"top_face\"\n").count - 1
        let uniquified = usda.components(separatedBy: "def GeomSubset \"top_face_2\"").count - 1
        #expect(plain == 1)
        #expect(uniquified == 1)
    }

    @Test func materialNamedSubsetKeepsItsBindingWhenAnotherSubsetCollides() throws {
        // The material-named subset must keep the sanitized material prim name
        // (its binding path depends on it); the plain tag gets the suffix.
        let steps = [
            RecipeStep(op: "tagSubset", select: RecipeSelector(facing: [0, -1, 0]),
                       subset: "red paint"),
            RecipeStep(op: "assignMaterial", select: RecipeSelector(facing: [0, 1, 0]),
                       material: "red_paint"),
        ]
        let recipe = ModelRecipe(
            name: "m",
            materials: [RecipeMaterial(name: "red_paint", diffuseColor: [1, 0, 0])],
            parts: [box(steps: steps)])
        let usda = USDAWriter.usda(for: try RecipeEngine.execute(recipe))
        #expect(usda.contains("def GeomSubset \"red_paint\" ("))          // bound one
        #expect(usda.contains("rel material:binding = </m/Materials/red_paint>"))
        #expect(usda.contains("def GeomSubset \"red_paint_2\"\n"))        // plain tag
        #expect(!usda.contains("</m/Materials/red_paint_2>"))
    }

    // MARK: - Selector edge cases

    @Test func facingZeroDirectionIsATypedError() {
        let steps = [RecipeStep(op: "inset", select: RecipeSelector(facing: [0, 0, 0]),
                                fraction: 0.2)]
        expectRecipeError(ModelRecipe(name: "m", parts: [box(steps: steps)]),
                          containing: "zero-length")
    }

    @Test func falseLastAndBoundaryFlagsAreNotSelectionSources() {
        // {"last": false} used to count as a source and fall through to a
        // misleading "selected nothing" — it should read as no source at all.
        let steps = [RecipeStep(op: "inset",
                                select: RecipeSelector(last: false), fraction: 0.2)]
        expectRecipeError(ModelRecipe(name: "m", parts: [box(steps: steps)]),
                          containing: "exactly one source")

        let boundarySteps = [RecipeStep(op: "inset",
                                        select: RecipeSelector(boundary: false),
                                        fraction: 0.2)]
        expectRecipeError(ModelRecipe(name: "m", parts: [box(steps: boundarySteps)]),
                          containing: "exactly one source")
    }

    @Test func allFalseIsNotASelectionSource() {
        let steps = [RecipeStep(op: "inset",
                                select: RecipeSelector(all: false), fraction: 0.2)]
        expectRecipeError(ModelRecipe(name: "m", parts: [box(steps: steps)]),
                          containing: "exactly one source")
    }
}
