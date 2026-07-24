// Spec: specs/agent-live-editing.md — unified MCP render path. The agent's
// `render_views` renders through the SAME RealityKit pipeline the user sees in
// the viewport (Entity.load + the QuickLook key/fill rig), rather than a
// separate SceneKit approximation. This file is the sanctioned "extend the
// viewport with a headless snapshot" path (CLAUDE.md: ONE renderer).

import Foundation
import simd

/// Pure, GPU-free camera math shared by the headless snapshot renderer. Split
/// out so it can be exhaustively unit-tested without a Metal device — the
/// render backends must agree on framing, so this is the single source of
/// truth for the focal-length → FOV and USD-transform → camera-matrix mapping.
public enum HeadlessCameraMath {

    /// USD's default vertical film aperture (mm). The `render_views` camera prims
    /// are authored with the default aperture, so both render backends resolve
    /// field of view from focal length against this constant and frame alike.
    public static let verticalApertureMM = 15.2908

    /// Vertical field of view in degrees for a `focalLength` (mm) against the USD
    /// default vertical aperture. Mirrors the native SceneKit renderer's formula
    /// so the RealityKit and SceneKit backends produce the same framing.
    public static func verticalFOVDegrees(focalLength: Double,
                                          apertureMM: Double = verticalApertureMM) -> Double {
        let focal = max(focalLength, 1e-4)
        return 2 * atan(apertureMM / (2 * focal)) * 180 / .pi
    }

    /// Build a column-major camera-to-world `float4x4` from the render tool's
    /// row-major, row-vector transform (16 values: three basis rows then the eye
    /// row, as authored by `RenderTools.lookAt`). USD stores the transform in
    /// row-vector form where each logical row is a basis vector (and the last is
    /// the eye); those rows map directly onto simd's column vectors, so no
    /// transpose is required. Returns `nil` unless exactly 16 values are given.
    public static func cameraToWorld(rowMajor rows: [Double]) -> float4x4? {
        guard rows.count == 16 else { return nil }
        let m = rows.map(Float.init)
        return float4x4(columns: (
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])))
    }
}

#if canImport(RealityKit)
import AppKit
import RealityKit

/// Offscreen RealityKit snapshot of a USD file through the on-screen viewport's
/// own pipeline: `Entity.load(contentsOf:)` (native USD materials/skinning) plus
/// the QuickLook key/fill rig applied by ``ViewportCoordinator``. Returns PNG
/// bytes so AgentMCP's `render_views` shows the agent exactly what the user sees.
///
/// Requires a live window-server + GPU context, which an app-hosted MCP session
/// has; the headless CLI server keeps the native SceneKit backend (there is no
/// drawable there to render into).
@MainActor
public struct ViewportSnapshotRenderer {

    public init() {}

    public enum SnapshotError: Error, Equatable {
        case noImage
        case encodeFailed
    }

    // coverage:disable — drives RealityKit/Metal offscreen (needs a GPU + window
    // server). The pure camera math above is unit-tested, the app-side selection
    // and adapter are tested in RenderKit, and the rendered pixels are checked on
    // a real machine (the `verify` skill / golden-image harness), never in CI.

    /// Render `fileURL` at `cameraToWorld` / `fovDegrees` to PNG data at
    /// `size`×`size`. The ARView is hosted in a never-shown borderless window so
    /// RealityKit has a real drawable to render into (the offscreen idiom used by
    /// Tools/EditorHarness/Render.swift).
    public func renderPNG(fileURL: URL, cameraToWorld: float4x4,
                          fovDegrees: Float, size: Int) async throws -> Data {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let window = NSWindow(contentRect: rect, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let arView = InteractiveARView(frame: rect)
        window.contentView = arView

        let coordinator = ViewportCoordinator()
        coordinator.attach(to: arView)
        // Same studio backdrop + QuickLook key/fill rig + contact shadow the
        // viewport's "AR preview" environment uses, so the pixels match.
        coordinator.applyEnvironment(EnvironmentSettings(background: .arPreview,
                                                         lighting: .quickLook))
        try coordinator.loadEntitiesForSnapshot(url: fileURL)
        coordinator.applyCameraMatrix(cameraToWorld, fovDegrees: fovDegrees)

        // Yield to the main runloop so RealityKit resolves resources and its
        // display link renders at least one frame before we snapshot a static
        // scene. Awaiting sleep (rather than spinning the runloop, which is
        // banned from async contexts) hands the main thread back to that loop.
        try await Task.sleep(nanoseconds: 150_000_000)

        // Encode to PNG *inside* the snapshot callback: NSImage is not Sendable, so
        // resuming the continuation with it would send a non-Sendable value across
        // isolation boundaries (a strict-concurrency error). `Data` is Sendable, so
        // the image never leaves the callback.
        let png: Data = try await withCheckedThrowingContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                guard let image else {
                    continuation.resume(throwing: SnapshotError.noImage)
                    return
                }
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: SnapshotError.encodeFailed)
                    return
                }
                continuation.resume(returning: data)
            }
        }
        window.contentView = nil
        return png
    }
    // coverage:enable
}
#endif
