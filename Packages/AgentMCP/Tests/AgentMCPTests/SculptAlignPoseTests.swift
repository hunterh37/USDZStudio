import Foundation
import SculptKit
import Testing
import USDCore
@testable import AgentMCP
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

#if canImport(ImageIO)
/// Sculpt-accuracy P3 (#84): the `sculpt_align_pose` tool — pose alignment by
/// analysis-by-synthesis over the injected renderer seam. The pure search math
/// is covered in SculptKit's `PoseAlignmentTests`; these tests cover the tool
/// wiring: matting intake, camera authoring per candidate, error surfaces, and
/// the baseline/ablation payload.
@Suite struct SculptAlignPoseTests {

    /// A renderer that writes a real decodable PNG for every candidate pose
    /// (a centered square silhouette), and records how often it ran.
    struct SilhouetteRenderer: RenderExecuting {
        let recorded: @Sendable () -> Void
        func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
            // The authored stage must exist and contain the candidate camera.
            let usda = try String(contentsOf: stageURL, encoding: .utf8)
            guard usda.contains(String(cameraPath.dropFirst())) else {
                throw ToolError.failed("camera \(cameraPath) missing from stage")
            }
            SculptVerifiableFidelityTests.centeredSquarePNG(outputURL, dim: 64, side: 32)
            recorded()
        }
    }

    /// A renderer that writes bytes no image decoder accepts.
    struct JunkRenderer: RenderExecuting {
        func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
            try Data("not-a-png".utf8).write(to: outputURL)
        }
    }

    static func referencePNG(in dir: URL) -> String {
        let url = dir.appendingPathComponent("align-ref.png")
        SculptVerifiableFidelityTests.centeredSquarePNG(url, dim: 64, side: 32)
        return url.path
    }

    @Test func alignsPoseAndReportsBaselineAblation() async {
        let counter = Recorder()
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                renderer: SilhouetteRenderer(recorded: { counter.append(.init(camera: "", size: 0)) }),
                workDirectory: work))
        let reference = Self.referencePNG(in: work)

        let out = await callOK(server, "sculpt_align_pose", [
            "referencePath": .string(reference),
            "includeBaseline": true,
        ])
        // Every render is identical, so the score surface is flat: the search
        // deterministically keeps the first candidate and the baseline ties it.
        #expect(out["azimuth"].doubleValue == 0)
        #expect(out["elevation"].doubleValue == 5)
        #expect(out["evaluations"].intValue == 64)
        #expect(out["coarseAzimuth"].doubleValue == 0)
        #expect(out["shapeScore"].doubleValue ?? 0 > 0.9)   // same silhouette both sides
        #expect(out["poseGain"].doubleValue == 0)
        #expect(out["baselineShapeScore"].doubleValue == out["shapeScore"].doubleValue)
        // The winning view is persisted for sculpt_comparison_sheet.
        let renderPath = out["renderPath"].stringValue ?? ""
        #expect(FileManager.default.fileExists(atPath: renderPath))
        // estimate (64) + best re-render (1) + baseline (16).
        #expect(counter.snapshot().count == 81)

        // Isolated-subtree variant exercises the paths argument.
        let solo = await callOK(server, "sculpt_align_pose", [
            "referencePath": .string(reference),
            "paths": ["/Root/Box"],
        ])
        #expect(solo["baselineShapeScore"] == .null)
        #expect(solo["evaluations"].intValue == 64)
    }

    @Test func surfacesErrorsStructurally() async {
        let work = Fixtures.tempDirectory()
        let renderer = SilhouetteRenderer(recorded: {})
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(renderer: renderer, workDirectory: work))
        let reference = Self.referencePNG(in: work)

        // Missing / undecodable reference.
        _ = await callError(server, "sculpt_align_pose")
        let bad = await callError(server, "sculpt_align_pose", ["referencePath": "/missing.png"])
        #expect(bad.contains("could not decode"))

        // Size bounds.
        let tiny = await callError(server, "sculpt_align_pose", [
            "referencePath": .string(reference), "size": 8,
        ])
        #expect(tiny.contains("64...1024"))

        // No renderer configured.
        let bare = Fixtures.server(session: Fixtures.session())
        let unsupported = await callError(bare, "sculpt_align_pose", ["referencePath": .string(reference)])
        #expect(unsupported.contains("without a renderer"))

        // No renderable geometry.
        let empty = EditSession(snapshot: StageSnapshot(
            rootPrims: [Prim(path: PrimPath("/Empty")!, typeName: "Xform")]))
        let emptyServer = Fixtures.server(
            session: empty,
            configuration: .init(renderer: renderer, workDirectory: Fixtures.tempDirectory()))
        let nothing = await callError(emptyServer, "sculpt_align_pose", ["referencePath": .string(reference)])
        #expect(nothing.contains("nothing renderable"))

        // Renderer failure surfaces with the candidate pose named.
        let failing = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                renderer: StubRenderer(recorded: { _ in }, failFor: "alignPose"),
                workDirectory: Fixtures.tempDirectory()))
        let failed = await callError(failing, "sculpt_align_pose", ["referencePath": .string(reference)])
        #expect(failed.contains("pose render"))

        // A render that decodes to nothing is a structural error, not a crash.
        let junk = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(renderer: JunkRenderer(), workDirectory: Fixtures.tempDirectory()))
        let undecoded = await callError(junk, "sculpt_align_pose", ["referencePath": .string(reference)])
        #expect(undecoded.contains("did not decode"))
    }
}
#endif
