import Foundation
import MeshKit

/// `dicyanin-usdz build <recipe.json> <out.usda> [--json]` — the agent
/// modeling loop's execute step (specs/mesh-editing.md, agent-first): a
/// declarative recipe goes in, invariant-checked geometry and a
/// machine-readable report come out.
enum BuildCommand {

    /// Machine-readable build report (`--json`): per-part step deltas plus
    /// scene totals — everything an agent needs to check its predictions
    /// before spending a render.
    struct Report: Codable {
        struct Part: Codable {
            var name: String
            var vertices: Int
            var edges: Int
            var faces: Int
            var triangles: Int
            var closed: Bool
            var volume: Double
            var boundsMin: [Double]
            var boundsMax: [Double]
            var steps: [RecipeStepReport]
        }

        var output: String
        var totalVertices: Int
        var totalFaces: Int
        var totalTriangles: Int
        var parts: [Part]
    }

    static func run(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void,
        writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1) },
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> Int32 {
        var positional: [String] = []
        var json = false
        for argument in arguments {
            switch argument {
            case "--json": json = true
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)\n" + CLIRunner.usage)
                    return 2
                }
                positional.append(argument)
            }
        }
        guard positional.count == 2 else {
            printError("error: build needs a recipe and an output\n" + CLIRunner.usage)
            return 2
        }
        let recipeURL = URL(fileURLWithPath: positional[0])
        let outputURL = URL(fileURLWithPath: positional[1])
        guard outputURL.pathExtension.lowercased() == "usda" else {
            printError("error: build output must be .usda")
            return 2
        }

        let recipeData: Data
        do {
            recipeData = try readFile(recipeURL)
        } catch {
            printError("error: could not read recipe \(recipeURL.path)")
            return 1
        }

        do {
            let recipe = try RecipeEngine.decode(recipeData)
            let result = try RecipeEngine.execute(recipe)
            try writeFile(Data(USDAWriter.usda(for: result).utf8), outputURL)

            let report = report(for: result, output: outputURL.path)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                output(String(decoding: try encoder.encode(report), as: UTF8.self))
            } else {
                render(report, print: output)
            }
            return 0
        } catch let error as RecipeError {
            printError("error: \(error.description)")
            return 1
        } catch {
            printError("error: \(error)")
            return 1
        }
    }

    static func report(for result: RecipeBuildResult, output: String) -> Report {
        Report(
            output: output,
            totalVertices: result.totalVertices,
            totalFaces: result.totalFaces,
            totalTriangles: result.totalTriangles,
            parts: result.parts.map { part in
                let mesh = part.mesh
                let points = mesh.vertexOrder.map { mesh.positions[$0]! }
                let (lo, hi) = USDAWriter.extent(of: points)
                return Report.Part(
                    name: part.name,
                    vertices: mesh.vertexCount,
                    edges: mesh.edgeCount,
                    faces: mesh.faceCount,
                    triangles: part.flat.faceVertexCounts.reduce(0) { $0 + max(0, $1 - 2) },
                    closed: mesh.boundaryEdges.isEmpty,
                    volume: mesh.signedVolume,
                    boundsMin: [lo.x, lo.y, lo.z],
                    boundsMax: [hi.x, hi.y, hi.z],
                    steps: part.stepReports)
            })
    }

    static func render(_ report: Report, print output: (String) -> Void) {
        for part in report.parts {
            let shape = part.closed ? "closed" : "open"
            output("part \(part.name): V\(part.vertices) E\(part.edges) F\(part.faces) (\(part.triangles) tris, \(shape))")
            for step in part.steps {
                output("  step \(step.index) \(step.op): \(step.selectedComponents) selected, ΔV\(step.deltaVertices) ΔE\(step.deltaEdges) ΔF\(step.deltaFaces)")
            }
        }
        output("wrote \(report.output) — \(report.parts.count) part(s), \(report.totalTriangles) tris")
    }
}
