import Foundation
import SwiftUI
import USDCore
import EditingKit
import USDBridge
import MeshKit
import EditorUI

/// Runs a `Scenario` against the **real** `EditorDocument` and the **real**
/// SwiftUI panels — the same types the app builds — and records what happened.
///
/// The harness deliberately drives the document rather than synthesising mouse
/// events: an `EditorDocument` mutation is exactly what a click on the inspector
/// produces (the views are thin bindings over these methods), and it needs no
/// window, no focus, and no accessibility permissions. What the views *look* like
/// is captured separately, by rendering them offscreen (`shot`).
@MainActor
final class Driver {
    private var document: EditorDocument?
    private let outputDirectory: URL
    private let baseDirectory: URL
    /// Human-readable log of every step, printed and written to the run report.
    private(set) var transcript: [String] = []
    private(set) var shots: [URL] = []

    init(outputDirectory: URL, baseDirectory: URL) {
        self.outputDirectory = outputDirectory
        self.baseDirectory = baseDirectory
    }

    func run(_ scenario: Scenario) async throws {
        let stageURL = resolve(scenario.open)
        let snapshot = try await StageLoader.load(stageURL)
        document = EditorDocument(snapshot: snapshot, modelURL: stageURL)
        log("open \(stageURL.lastPathComponent) → \(snapshot.primCount) prims")

        for (index, step) in scenario.steps.enumerated() {
            try await perform(step, index: index + 1)
        }
    }

    // MARK: Steps

    private func perform(_ step: Scenario.Step, index: Int) async throws {
        guard let document else {
            throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no open stage")
        }
        switch step.do {
        case "select":
            let path = try primPath(step.path, step: index, verb: step.do)
            guard document.snapshot.prim(at: path) != nil else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no prim at \(path)")
            }
            document.selection = Selection([path])
            log("select \(path)")

        case "shot":
            let name = step.name ?? "shot-\(index)"
            let url = try shot(named: name, tab: step.tab, document: document)
            shots.append(url)
            log("shot \(name) → \(url.lastPathComponent)")

        case "material.set":
            let (input, material) = try materialTarget(step, index: index, document: document)
            let value = try attributeValue(step, input: input, index: index)
            guard document.setMaterialInput(input, on: material, to: value) else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do,
                    detail: "rejected \(input.name)=\(describe(value)) (illegal or unchanged)")
            }
            log("material.set \(input.name)=\(describe(value)) on \(material.name) → \(document.undoLabel ?? "?")")

        case "material.clear":
            let (input, material) = try materialTarget(step, index: index, document: document)
            guard document.clearMaterialInput(input, on: material) else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do, detail: "\(input.name) was not authored")
            }
            log("material.clear \(input.name) on \(material.name)")

        case "material.create":
            let path: PrimPath
            if let raw = step.path { path = try primPath(raw, step: index, verb: step.do) }
            else if let primary = document.selection.primary { path = primary }
            else { throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no path and no selection") }
            let color = step.color ?? [0.18, 0.18, 0.18]
            guard document.createAndBindMaterial(to: path, baseColor: color) else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do, detail: "could not create material on \(path)")
            }
            log("material.create on \(path) → \(document.undoLabel ?? "?")")

        case "material.recolor":
            let scope = document.selection.paths.isEmpty
                ? (step.path.flatMap(PrimPath.init).map { [$0] } ?? [])
                : document.selection.paths
            let materials = document.materials(under: scope)
            guard let name = step.input ?? "diffuseColor" as String?,
                  let input = PreviewSurfaceInput.named(name) else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "unknown input")
            }
            let value = try attributeValue(step, input: input, index: index)
            guard document.recolorMaterials(materials, input: input, to: value) else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do,
                    detail: "recolor of \(materials.count) materials was a no-op")
            }
            log("material.recolor \(input.name)=\(describe(value)) across \(materials.count) materials → \(document.undoLabel ?? "?")")

        case "undo":
            let n = step.count ?? 1
            for _ in 0..<n {
                let label = document.undoLabel
                guard document.canUndo else {
                    throw HarnessError.stepFailed(step: index, verb: step.do, detail: "nothing to undo")
                }
                document.undo()
                log("undo \(label ?? "?")")
            }

        case "redo":
            let n = step.count ?? 1
            for _ in 0..<n {
                let label = document.redoLabel
                guard document.canRedo else {
                    throw HarnessError.stepFailed(step: index, verb: step.do, detail: "nothing to redo")
                }
                document.redo()
                log("redo \(label ?? "?")")
            }

        case "mesh.enter":
            let path: PrimPath
            if let raw = step.path { path = try primPath(raw, step: index, verb: step.do) }
            else if let primary = document.selection.primary { path = primary }
            else { throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no path and no selection") }
            let availability = document.enterMeshEditMode(at: path)
            guard availability == .available else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do,
                    detail: availability.refusalMessage ?? "unavailable")
            }
            log("mesh.enter \(path) → \(document.meshEdit?.session.mesh.faceCount ?? 0) faces")

        case "mesh.tool":
            guard document.meshEdit != nil else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "not in edit mode")
            }
            guard let name = step.name, let tool = MeshTool(rawValue: name) else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "unknown tool '\(step.name ?? "")'")
            }
            document.meshEdit?.tool = tool
            if let number = step.number {
                switch tool {
                case .extrude: document.meshEdit?.extrudeDistance = number
                case .inset: document.meshEdit?.insetFraction = number
                case .merge: document.meshEdit?.mergeDistance = number
                case .bevel: document.meshEdit?.bevelWidth = number
                case .delete, .fill: break
                }
            }
            log("mesh.tool \(tool.label)\(step.number.map { " (\($0))" } ?? "")")

        case "mesh.selectFaces":
            guard document.meshEdit != nil else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "not in edit mode")
            }
            let order = document.meshEdit!.session.mesh.faceOrder
            let ids = try (step.faces ?? []).map { i -> FaceID in
                guard order.indices.contains(i) else {
                    throw HarnessError.stepFailed(step: index, verb: step.do, detail: "face index \(i) out of range")
                }
                return order[i]
            }
            document.meshEdit?.componentSelection = .faces(Set(ids))
            log("mesh.selectFaces \(step.faces ?? [])")

        case "mesh.apply":
            guard document.meshEdit != nil else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "not in edit mode")
            }
            document.applyActiveMeshTool()
            if let diagnostic = document.meshEdit?.lastDiagnostic {
                log("mesh.apply → refused: \(diagnostic)")
            } else {
                log("mesh.apply → \(document.meshEdit?.session.journal.last ?? "?") (\(document.meshEdit?.session.mesh.faceCount ?? 0) faces)")
            }

        case "save":
            guard let raw = step.path else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "save needs a path")
            }
            let target = resolve(raw)
            let executor = ProcessBridgeExecutor(scriptPath: StageLoader.snapshotScriptPath)
            try await document.save(to: target, executor: executor)
            log("save → \(target.lastPathComponent)")

        case "reopen":
            guard let raw = step.path else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "reopen needs a path")
            }
            let url = resolve(raw)
            let snapshot = try await StageLoader.load(url)
            self.document = EditorDocument(snapshot: snapshot, modelURL: url)
            log("reopen \(url.lastPathComponent) → \(snapshot.primCount) prims")

        case "mesh.exit":
            document.exitMeshEditMode(commit: step.commit ?? true)
            log("mesh.exit commit=\(step.commit ?? true) → \(document.undoLabel ?? "no command")")

        case "gizmo.drag":
            // The full drag lifecycle the viewport reports for an arrow grab:
            // began → changed(distance) → ended, against the live selection.
            guard let raw = step.axis else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no axis (x|y|z)")
            }
            guard let distance = step.number else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no drag distance (number)")
            }
            guard document.performTranslateGizmoDrag(axis: raw, distance: distance) else {
                throw HarnessError.stepFailed(
                    step: index, verb: step.do,
                    detail: "drag refused (gizmo hidden or axis not x|y|z: '\(raw)')")
            }
            log("gizmo.drag \(raw) by \(distance) → \(document.undoLabel ?? "no command")")

        case "expect":
            try expect(step, index: index, document: document)

        case "dump":
            log(StateDump.text(document))

        default:
            throw HarnessError.stepFailed(step: index, verb: step.do, detail: "unknown verb")
        }
    }

    /// Assertions — what makes a scenario a pipeline rather than a demo. A
    /// failure throws, and the run exits non-zero.
    private func expect(_ step: Scenario.Step, index: Int, document: EditorDocument) throws {
        if let inputName = step.materialInput {
            let (input, material) = try materialTarget(
                Scenario.Step(do: step.do, path: step.path, input: inputName),
                index: index, document: document)
            let actual = document.materialInput(input, on: material)

            if step.isNull == true {
                guard actual == nil else {
                    throw HarnessError.expectationFailed(
                        step: index,
                        detail: "\(input.name) expected unauthored, got \(describe(actual!))")
                }
                log("expect \(input.name) unauthored ✓")
                return
            }
            let wanted = try attributeValue(step, input: input, index: index)
            guard let actual, Driver.matches(actual, wanted) else {
                throw HarnessError.expectationFailed(
                    step: index,
                    detail: "\(input.name) expected \(precise(wanted)), got \(actual.map(precise) ?? "unauthored")")
            }
            log("expect \(input.name) == \(describe(wanted)) ✓")
            return
        }
        if let wanted = step.faceCount {
            let actual: Int
            if let session = document.meshEdit?.session {
                actual = session.mesh.faceCount
            } else if let primary = document.selection.primary,
                      case .intArray(let counts)? =
                        document.snapshot.prim(at: primary)?.attribute(named: "faceVertexCounts")?.value {
                actual = counts.count
            } else {
                throw HarnessError.expectationFailed(step: index, detail: "no mesh to count faces on")
            }
            guard actual == wanted else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "faceCount expected \(wanted), got \(actual)")
            }
            log("expect faceCount == \(wanted) ✓")
            return
        }
        if let wanted = step.activeTool {
            let actual = document.meshEdit?.tool?.rawValue ?? ""
            guard actual == wanted else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "activeTool expected '\(wanted)', got '\(actual)'")
            }
            log("expect activeTool == '\(wanted)' ✓")
            return
        }
        if let wanted = step.meshDiagnostic {
            let actual = document.meshEdit?.lastDiagnostic ?? ""
            let ok = wanted.isEmpty ? actual.isEmpty : actual.contains(wanted)
            guard ok else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "meshDiagnostic expected '\(wanted)', got '\(actual)'")
            }
            log("expect meshDiagnostic \(wanted.isEmpty ? "none" : "contains '\(wanted)'") ✓")
            return
        }
        if let wanted = step.hasMaterial {
            let path: PrimPath
            if let raw = step.path, let parsed = PrimPath(raw) { path = parsed }
            else if let primary = document.selection.primary { path = primary }
            else { throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no path and no selection") }
            let actual = document.boundMaterial(for: path) != nil
            guard actual == wanted else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "hasMaterial expected \(wanted), got \(actual) at \(path)")
            }
            log("expect hasMaterial == \(wanted) at \(path) ✓")
            return
        }
        if let wanted = step.surfacePath {
            let material = try resolvedMaterial(step, index: index, document: document)
            guard material.surfacePath.description == wanted else {
                throw HarnessError.expectationFailed(
                    step: index,
                    detail: "surfacePath expected \(wanted), got \(material.surfacePath)")
            }
            log("expect surfacePath == \(wanted) ✓")
            return
        }
        if let wanted = step.translation {
            let path: PrimPath
            if let raw = step.path, let parsed = PrimPath(raw) { path = parsed }
            else if let primary = document.selection.primary { path = primary }
            else { throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no path and no selection") }
            let actual = document.transform(at: path).translation
            guard wanted.count == 3,
                  zip(actual, wanted).allSatisfy({ abs($0 - $1) <= 1e-6 }) else {
                throw HarnessError.expectationFailed(
                    step: index,
                    detail: "translation expected \(wanted), got \(actual) at \(path)")
            }
            log("expect translation == \(wanted) at \(path) ✓")
            return
        }
        if let wanted = step.gizmoVisible {
            let actual = document.translateGizmoOrigin != nil
            guard actual == wanted else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "gizmoVisible expected \(wanted), got \(actual)")
            }
            log("expect gizmoVisible == \(wanted) ✓")
            return
        }
        if let wanted = step.gizmoOrigin {
            guard let actual = document.translateGizmoOrigin else {
                throw HarnessError.expectationFailed(step: index, detail: "gizmo not visible")
            }
            guard wanted.count == 3,
                  zip(actual, wanted).allSatisfy({ abs($0 - $1) <= 1e-6 }) else {
                throw HarnessError.expectationFailed(
                    step: index, detail: "gizmoOrigin expected \(wanted), got \(actual)")
            }
            log("expect gizmoOrigin == \(wanted) ✓")
            return
        }
        throw HarnessError.stepFailed(step: index, verb: "expect", detail: "no expectation named")
    }

    // MARK: Resolution helpers

    private func materialTarget(
        _ step: Scenario.Step, index: Int, document: EditorDocument
    ) throws -> (PreviewSurfaceInput, ResolvedMaterial) {
        guard let name = step.input ?? step.materialInput,
              let input = PreviewSurfaceInput.named(name) else {
            throw HarnessError.stepFailed(
                step: index, verb: step.do,
                detail: "unknown input '\(step.input ?? step.materialInput ?? "")'")
        }
        return (input, try resolvedMaterial(step, index: index, document: document))
    }

    /// The material for the step's `path`, defaulting to the current selection —
    /// resolved exactly as the inspector resolves it.
    private func resolvedMaterial(
        _ step: Scenario.Step, index: Int, document: EditorDocument
    ) throws -> ResolvedMaterial {
        let path: PrimPath
        if let raw = step.path, let parsed = PrimPath(raw) {
            path = parsed
        } else if let primary = document.selection.primary {
            path = primary
        } else {
            throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no path and no selection")
        }
        guard let material = document.boundMaterial(for: path) else {
            throw HarnessError.stepFailed(
                step: index, verb: step.do, detail: "no material bound to \(path)")
        }
        return material
    }

    private func attributeValue(
        _ step: Scenario.Step, input: PreviewSurfaceInput, index: Int
    ) throws -> AttributeValue {
        if let color = step.color {
            guard color.count == 3 else {
                throw HarnessError.stepFailed(step: index, verb: step.do, detail: "color needs 3 components")
            }
            return .vector(color)
        }
        if let number = step.number {
            // `useSpecularWorkflow` is the one int-typed input; JSON has one
            // number type, so the catalog decides how to read it.
            if case .choice = input.kind { return .int(Int(number)) }
            return .double(number)
        }
        if let string = step.string { return .token(string) }
        throw HarnessError.stepFailed(step: index, verb: step.do, detail: "no value given")
    }

    private func primPath(_ raw: String?, step: Int, verb: String) throws -> PrimPath {
        guard let raw, let path = PrimPath(raw) else {
            throw HarnessError.stepFailed(step: step, verb: verb, detail: "invalid path '\(raw ?? "")'")
        }
        return path
    }

    /// Absolute paths are used as-is; relative ones resolve against the
    /// workspace root, so a scenario reads `Tests/Fixtures/car.usda` regardless
    /// of where the scenario file itself lives or where the tool was invoked.
    /// Falls back to the scenario's own directory outside a workspace.
    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let root = RepoRoot.find(hint: baseDirectory) ?? baseDirectory
        return root.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: Capture

    /// Renders the real `InspectorView` for the current document state — or,
    /// for `tab: "mesh"`, the mesh edit-mode viewport overlay on a
    /// viewport-colored backdrop (the RealityKit frame itself has no harness
    /// surface; the overlay chrome is what's under review).
    private func shot(named name: String, tab: String?, document: EditorDocument) throws -> URL {
        let url = outputDirectory.appendingPathComponent("\(name).png")
        // The object-mode shortcut hint bar over the same viewport backdrop
        // (renders empty in edit mode by design — that's an assertion too).
        if tab == "hints" {
            try Render.png(
                ZStack(alignment: .bottom) {
                    Color(red: 0.05, green: 0.06, blue: 0.075) // Palette.viewportBackground
                    ViewportHintOverlay(document: document)
                },
                size: CGSize(width: 960, height: 200),
                to: url)
            return url
        }
        if tab == "mesh" {
            try Render.png(
                ZStack {
                    Color(red: 0.05, green: 0.06, blue: 0.075) // Palette.viewportBackground
                    MeshEditOverlay(document: document)
                },
                size: CGSize(width: 960, height: 560),
                to: url)
            return url
        }
        let resolvedTab = InspectorView.Tab(rawValue: (tab ?? "prim").capitalized) ?? .prim
        try Render.png(
            InspectorView(document: document, initialTab: resolvedTab),
            size: CGSize(width: 320, height: 720),
            to: url)
        return url
    }

    /// Compares an expectation against a stage value with float tolerance.
    ///
    /// USD stores these inputs as 32-bit floats, so a `0.4` authored in a `.usda`
    /// arrives as `0.4000000059604645`. Exact `==` on doubles would make every
    /// numeric expectation unwritable — the tolerance is the point, not a
    /// shortcut. It's set an order of magnitude above float32 epsilon and far
    /// below any value a human would author.
    static func matches(_ actual: AttributeValue, _ wanted: AttributeValue, tolerance: Double = 1e-6) -> Bool {
        switch (actual, wanted) {
        case let (.double(a), .double(b)):
            return abs(a - b) <= tolerance
        case let (.vector(a), .vector(b)):
            return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        default:
            return actual == wanted
        }
    }

    /// Full-precision rendering, for failure messages. `%g` rounds 0.4000000059
    /// to "0.4", which turns a real mismatch into "expected 0.4, got 0.4".
    private func precise(_ value: AttributeValue) -> String {
        switch value {
        case .double(let d): return String(format: "%.9g", d)
        case .vector(let v): return "(" + v.map { String(format: "%.9g", $0) }.joined(separator: ", ") + ")"
        default: return describe(value)
        }
    }

    private func describe(_ value: AttributeValue) -> String {
        switch value {
        case .double(let d): return String(format: "%g", d)
        case .int(let i): return String(i)
        case .vector(let v): return "(" + v.map { String(format: "%.3f", $0) }.joined(separator: ", ") + ")"
        default: return "\(value)"
        }
    }

    private func log(_ line: String) {
        transcript.append(line)
        print(line)
    }
}
