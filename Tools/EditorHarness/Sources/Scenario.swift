import Foundation

/// A scripted harness run, authored as JSON so a run is reviewable and
/// re-runnable rather than a pile of ad-hoc flags.
///
/// ```json
/// { "name": "material-edit",
///   "open": "Tests/Fixtures/car.usda",
///   "steps": [
///     { "do": "select", "path": "/Car/Body" },
///     { "do": "shot", "name": "before", "tab": "material" },
///     { "do": "material.set", "input": "roughness", "number": 0.9 },
///     { "do": "expect", "materialInput": "roughness", "number": 0.9 },
///     { "do": "undo" },
///     { "do": "expect", "materialInput": "roughness", "number": 0.4 }
///   ] }
/// ```
struct Scenario: Decodable {
    var name: String
    /// Stage to open through the real bridge. Relative paths resolve against
    /// the scenario file's directory.
    var open: String
    var steps: [Step]

    struct Step: Decodable {
        /// The verb. See `Driver` for the dispatch table.
        var `do`: String

        // Operands — each verb reads the ones it needs.
        var path: String?
        var name: String?
        var tab: String?
        var input: String?
        var number: Double?
        var color: [Double]?
        var string: String?
        var count: Int?

        // Mesh edit mode operands (Phase 6).
        /// Face indices (import order) for `mesh.selectFaces`.
        var faces: [Int]?
        /// For `mesh.exit`: commit the session to the stage (default true).
        var commit: Bool?

        // Translate gizmo operands.
        /// Axis for `gizmo.drag` ("x" | "y" | "z"); drag distance rides in
        /// `number` (world units).
        var axis: String?

        // Expectations.
        /// Assert the step's path/selection prim's local translation.
        var translation: [Double]?
        /// Assert whether the object-mode move gizmo is showing.
        var gizmoVisible: Bool?
        /// Assert the move gizmo's world-space origin.
        var gizmoOrigin: [Double]?
        /// Assert the named input's value (with `number`/`color`, or `isNull`).
        var materialInput: String?
        /// Assert the input carries no authored opinion.
        var isNull: Bool?
        /// Assert which prim the selection's material inputs resolve to.
        var surfacePath: String?
        /// Assert whether a material is bound to the step's path/selection.
        var hasMaterial: Bool?
        /// Assert the face count — of the edit session's working mesh while in
        /// edit mode, else of the selected prim's authored faceVertexCounts.
        var faceCount: Int?
        /// Assert the edit session's active tool (empty string = none).
        var activeTool: String?
        /// Assert the last op refusal contains this substring ("" = none).
        var meshDiagnostic: String?
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case usage(String)
    case badScenario(String)
    case renderFailed(String)
    case stepFailed(step: Int, verb: String, detail: String)
    case expectationFailed(step: Int, detail: String)

    var description: String {
        switch self {
        case .usage(let s): return s
        case .badScenario(let s): return "bad scenario: \(s)"
        case .renderFailed(let s): return "could not render \(s)"
        case let .stepFailed(step, verb, detail):
            return "step \(step) (\(verb)) failed: \(detail)"
        case let .expectationFailed(step, detail):
            return "step \(step) expectation failed: \(detail)"
        }
    }
}
