import AgentMCP
import Foundation
import USDBridge

/// `usdrecord`-backed renderer for AgentMCP's `render_views`. Opt-in via
/// `DICYANIN_USDRECORD` (see `NativeRendererSelection`); the native SceneKit
/// renderer is the default so no `usd-core`/`usdrecord` is required.
public struct UsdrecordRenderer: RenderExecuting {
    public var usdrecordPath: String

    public init(usdrecordPath: String) {
        self.usdrecordPath = usdrecordPath
    }

    // coverage:disable — spawns the real usdrecord binary; the render tool's stage/camera authoring is unit-tested against a stub renderer.
    public func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: usdrecordPath)
        process.arguments = [
            "--imageWidth", String(size),
            "--camera", cameraPath,
            stageURL.path, outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.pythonUnavailable(detail: "usdrecord exited \(process.terminationStatus)")
        }
    }
    // coverage:enable
}
