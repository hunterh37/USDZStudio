import AgentMCP
import Foundation
import RenderKit
import ViewportKit
import simd

/// App-target adapter that satisfies AgentMCP's file-based `RenderExecuting`
/// contract by rendering through ViewportKit's headless RealityKit snapshot —
/// the SAME pipeline the user sees in the on-screen viewport. This is the
/// unified render path (specs/agent-live-editing.md): an app-hosted MCP session
/// answers `render_views` with real viewport pixels instead of the separate
/// SceneKit approximation.
///
/// Lives in the App target because only the composition root may import both
/// `ViewportKit` (RealityKit) and `AgentMCP` (`RenderExecuting`); the module
/// layering forbids either kit from importing the other. The App target is
/// un-coverage-gated, and the GPU snapshot can't run in CI, so the testable
/// pieces live in RenderKit (camera parse, backend selection) and ViewportKit
/// (camera math); the pixels are verified on a real machine.
struct ViewportKitRenderer: RenderExecuting {

    // coverage:disable — bridges onto the GPU snapshot renderer. The camera
    // parsing (RenderKit.RenderStageParse) and matrix/FOV math
    // (ViewportKit.HeadlessCameraMath) it composes are both unit-tested.
    func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        let usda = try String(contentsOf: stageURL, encoding: .utf8)
        let name = RenderStageParse.lastPathComponent(cameraPath)
        guard let parsed = RenderStageParse.camera(named: name, usda: usda),
              let cameraToWorld = HeadlessCameraMath.cameraToWorld(rowMajor: parsed.rows) else {
            throw ViewportRenderError.cameraUnavailable(cameraPath)
        }
        let fov = HeadlessCameraMath.verticalFOVDegrees(focalLength: parsed.focal)
        let png = try await ViewportSnapshotRenderer().renderPNG(
            fileURL: stageURL,
            cameraToWorld: cameraToWorld,
            fovDegrees: Float(fov),
            size: size)
        try png.write(to: outputURL)
    }
    // coverage:enable
}

enum ViewportRenderError: Error, Equatable {
    /// The render stage lacked a parseable camera prim at `cameraPath`, so the
    /// agent-authored pose can't be reproduced.
    case cameraUnavailable(String)
}
