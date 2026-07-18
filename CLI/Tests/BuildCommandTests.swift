import Testing
import Foundation
@testable import openusdz

@Suite("build subcommand")
struct BuildCommandTests {

    private final class Capture: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
        var written: [URL: Data] = [:]
    }

    /// Runs `build` fully in memory: recipe JSON in, written files captured.
    private func run(_ arguments: [String], recipe: String?) -> (Int32, Capture) {
        let capture = Capture()
        let code = BuildCommand.run(
            arguments: arguments,
            print: { capture.out.append($0) },
            printError: { capture.err.append($0) },
            writeFile: { data, url in capture.written[url] = data },
            readFile: { _ in
                guard let recipe else { throw CocoaError(.fileReadNoSuchFile) }
                return Data(recipe.utf8)
            })
        return (code, capture)
    }

    private let crateRecipe = """
    {
      "name": "Crate",
      "materials": [{"name": "Wood", "diffuseColor": [0.6, 0.4, 0.2]}],
      "parts": [{
        "name": "Body",
        "primitive": {"type": "box", "size": [2, 1, 1]},
        "material": "Wood",
        "steps": [
          {"op": "inset", "select": {"facing": [0, 1, 0]}, "fraction": 0.3},
          {"op": "extrude", "select": {"last": true}, "distance": -0.2}
        ]
      }]
    }
    """

    @Test func buildsARecipeAndWritesUSDA() throws {
        let (code, capture) = run(["recipe.json", "crate.usda"], recipe: crateRecipe)
        #expect(code == 0)
        let usda = String(decoding: try #require(
            capture.written[URL(fileURLWithPath: "crate.usda")]), as: UTF8.self)
        #expect(usda.hasPrefix("#usda 1.0"))
        #expect(usda.contains("def Mesh \"Geom\""))
        #expect(usda.contains("def Material \"Wood\""))
        // Human report: per-step deltas and a summary line.
        #expect(capture.out.contains { $0.contains("step 0 inset") })
        #expect(capture.out.contains { $0.hasPrefix("wrote ") && $0.contains("crate.usda") })
    }

    @Test func duplicateMaterialNamesFailCleanlyInsteadOfCrashing() {
        // "arm-1" and "arm_1" collide after USD sanitizing; the engine must
        // reject the recipe with a typed error before the writer ever runs.
        let recipe = """
        {
          "name": "M",
          "materials": [{"name": "arm-1", "diffuseColor": [1, 0, 0]},
                        {"name": "arm_1", "diffuseColor": [0, 1, 0]}],
          "parts": [{"name": "P", "primitive": {"type": "box"}, "material": "arm-1"}]
        }
        """
        let (code, capture) = run(["recipe.json", "m.usda"], recipe: recipe)
        #expect(code == 1)
        #expect(capture.written.isEmpty)
        #expect(capture.err.contains { $0.contains("duplicate material") })
    }

    @Test func jsonReportIsMachineReadable() throws {
        let (code, capture) = run(["recipe.json", "crate.usda", "--json"], recipe: crateRecipe)
        #expect(code == 0)
        let report = try JSONDecoder().decode(
            BuildCommand.Report.self,
            from: Data(capture.out.joined(separator: "\n").utf8))
        #expect(report.parts.count == 1)
        let part = report.parts[0]
        #expect(part.name == "Body")
        #expect(part.faces == 14) // box 6 → inset +4 → extrude +4
        #expect(part.closed)
        #expect(part.volume > 0 && part.volume < 2)
        #expect(part.steps.count == 2)
        #expect(part.steps[1].op == "extrude" && part.steps[1].deltaFaces == 4)
        #expect(part.boundsMin.count == 3 && part.boundsMax.count == 3)
        #expect(report.totalTriangles == part.triangles)
    }

    @Test func recipeErrorsSurfaceWithCoordinatesAndExit1() {
        let bad = """
        {"name": "X", "parts": [{"name": "P", "primitive": {"type": "box"},
          "steps": [{"op": "extrude", "select": {"all": true}}]}]}
        """
        let (code, capture) = run(["r.json", "x.usda"], recipe: bad)
        #expect(code == 1)
        #expect(capture.written.isEmpty)
        #expect(capture.err.contains { $0.contains("part 'P' step 0") && $0.contains("distance") })
    }

    @Test func invalidJSONExit1WithDecodeDiagnostic() {
        let (code, capture) = run(["r.json", "x.usda"], recipe: "{nope")
        #expect(code == 1)
        #expect(capture.err.contains { $0.contains("invalid recipe JSON") })
    }

    @Test func usageErrors() {
        // Missing args.
        #expect(run(["only-one.json"], recipe: nil).0 == 2)
        // Wrong output extension.
        let (code, capture) = run(["r.json", "out.usdz"], recipe: crateRecipe)
        #expect(code == 2)
        #expect(capture.err.contains { $0.contains(".usda") })
        // Unknown flag.
        #expect(run(["r.json", "out.usda", "--fast"], recipe: crateRecipe).0 == 2)
    }

    @Test func unreadableRecipeExit1() {
        let (code, capture) = run(["missing.json", "out.usda"], recipe: nil)
        #expect(code == 1)
        #expect(capture.err.contains { $0.contains("could not read recipe") })
    }
}
