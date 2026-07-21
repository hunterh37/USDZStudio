import Foundation
import Testing
@testable import openusdz

/// The render stage the tool hands the renderer is always `USDASerializer`
/// output: `UsdPreviewSurface` materials, `material:binding` on the meshes, and
/// one `Camera` prim per shot. These exercise the pure parsing the native
/// renderer relies on, with fixtures shaped exactly like that output.
@Suite("RenderStageParse")
struct RenderStageParseTests {

    /// A two-material stage with an authored perspective camera.
    static let stage = """
    #usda 1.0
    (
        defaultPrim = "World"
        upAxis = "Y"
    )

    def Xform "World"
    {
        def Mesh "Body"
        {
            int[] faceVertexCounts = [4]
            rel material:binding = </Looks/Gold>
        }

        def Mesh "Screen"
        {
            int[] faceVertexCounts = [4]
            rel material:binding = </Looks/Glass>
        }
    }

    def Scope "Looks"
    {
        def Material "Gold"
        {
            def Shader "Surface"
            {
                token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.85, 0.72, 0.55)
            }
        }

        def Material "Glass"
        {
            def Shader "Surface"
            {
                token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.1, 0.2, 0.9)
            }
        }
    }

    def Camera "AgentCam_persp"
    {
        double focalLength = 35
        matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0.5, 0.4, 0.6, 1) )
        uniform token[] xformOpOrder = ["xformOp:transform"]
    }
    """

    @Test func resolvesDiffuseColorsPerBoundPrim() {
        let colors = RenderStageParse.diffuseColorsByPrimName(usda: Self.stage)
        #expect(colors["Body"] == [0.85, 0.72, 0.55])
        #expect(colors["Screen"] == [0.1, 0.2, 0.9])
        #expect(colors.count == 2)
    }

    @Test func materialDiffuseIndexedByMaterialName() {
        let materials = RenderStageParse.materialDiffuse(usda: Self.stage)
        #expect(materials["Gold"] == [0.85, 0.72, 0.55])
        #expect(materials["Glass"] == [0.1, 0.2, 0.9])
    }

    @Test func bindingsMapPrimToMaterialLeaf() {
        let bindings = RenderStageParse.primBindings(usda: Self.stage)
        #expect(bindings["Body"] == "Gold")
        #expect(bindings["Screen"] == "Glass")
    }

    @Test func unboundPrimHasNoColor() {
        let stage = """
        def Mesh "Lonely"
        {
            int[] faceVertexCounts = [3]
        }
        """
        #expect(RenderStageParse.diffuseColorsByPrimName(usda: stage).isEmpty)
    }

    @Test func bindingToMissingMaterialIsDropped() {
        let stage = """
        def Mesh "Body" { rel material:binding = </Looks/Ghost> }
        def Scope "Looks" { def Material "Real" { def Shader "S" { color3f inputs:diffuseColor = (1, 0, 0) } } }
        """
        #expect(RenderStageParse.diffuseColorsByPrimName(usda: stage).isEmpty)
    }

    @Test func parsesCameraTransformAndFocal() throws {
        let cam = try #require(RenderStageParse.camera(named: "AgentCam_persp", usda: Self.stage))
        #expect(cam.rows.count == 16)
        // Row 3 (indices 12...14) is the eye position.
        #expect(cam.rows[12] == 0.5)
        #expect(cam.rows[13] == 0.4)
        #expect(cam.rows[14] == 0.6)
        #expect(cam.focal == 35)
    }

    @Test func cameraFocalDefaultsWhenAbsent() throws {
        let stage = """
        def Camera "AgentCam_front"
        {
            matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 2, 1) )
        }
        """
        let cam = try #require(RenderStageParse.camera(named: "AgentCam_front", usda: stage))
        #expect(cam.focal == 35)
        #expect(cam.rows[14] == 2)
    }

    @Test func missingCameraReturnsNil() {
        #expect(RenderStageParse.camera(named: "AgentCam_nope", usda: Self.stage) == nil)
    }

    @Test func cameraBlockStopsAtNextDefinition() throws {
        // A transform on a *later* prim must not leak into the camera parse.
        let stage = """
        def Camera "AgentCam_side"
        {
            double focalLength = 50
            matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (3, 0, 0, 1) )
        }
        def Mesh "Later"
        {
            matrix4d xformOp:transform = ( (9, 9, 9, 9), (9, 9, 9, 9), (9, 9, 9, 9), (9, 9, 9, 9) )
        }
        """
        let cam = try #require(RenderStageParse.camera(named: "AgentCam_side", usda: stage))
        #expect(cam.rows[12] == 3)
        #expect(cam.focal == 50)
    }

    // MARK: line helpers

    @Test func colorTripletRejectsWrongArity() {
        #expect(RenderStageParse.colorTriplet(after: "k", in: "k = (1, 2)") == nil)
        #expect(RenderStageParse.colorTriplet(after: "k", in: "no parens here") == nil)
    }

    @Test func lastPathComponentTakesLeaf() {
        #expect(RenderStageParse.lastPathComponent("/Looks/Gold") == "Gold")
        #expect(RenderStageParse.lastPathComponent("Bare") == "Bare")
    }

    @Test func scalarParsesNegativeAndDecimal() {
        #expect(RenderStageParse.scalar(after: "v", in: "double v = -1.5") == -1.5)
        #expect(RenderStageParse.scalar(after: "v", in: "no value") == nil)
    }
}

/// The renderer-selection policy: native by default, Storm only on explicit,
/// existing `DICYANIN_USDRECORD`.
@Suite("NativeRendererSelection")
struct NativeRendererSelectionTests {

    @Test func defaultsToNativeWhenNoOverride() {
        let r = NativeRendererSelection.make(environment: [:], fileExists: { _ in true })
        #expect(r is NativeSceneKitRenderer)
    }

    @Test func usesUsdrecordWhenOverrideExists() {
        let r = NativeRendererSelection.make(
            environment: ["DICYANIN_USDRECORD": "/opt/usd/bin/usdrecord"],
            fileExists: { $0 == "/opt/usd/bin/usdrecord" })
        let usd = try? #require(r as? UsdrecordRenderer)
        #expect(usd?.usdrecordPath == "/opt/usd/bin/usdrecord")
    }

    @Test func fallsBackToNativeWhenOverrideMissing() {
        // A stale/broken override path must not strand render_views: native wins.
        let r = NativeRendererSelection.make(
            environment: ["DICYANIN_USDRECORD": "/nope/usdrecord"],
            fileExists: { _ in false })
        #expect(r is NativeSceneKitRenderer)
    }

    @Test func emptyOverrideIsIgnored() {
        let r = NativeRendererSelection.make(
            environment: ["DICYANIN_USDRECORD": ""], fileExists: { _ in true })
        #expect(r is NativeSceneKitRenderer)
    }
}

/// Real offscreen render, opt-in via `RUN_NATIVE_RENDER_SMOKE=1` so CI never
/// depends on GPU behaviour. Locally it proves the SceneKit path writes pixels.
@Suite("NativeSceneKitRenderer smoke")
struct NativeRenderSmokeTests {

    @Test func rendersAuthoredStageToPNG() async throws {
        guard ProcessInfo.processInfo.environment["RUN_NATIVE_RENDER_SMOKE"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stageURL = dir.appendingPathComponent("stage.usda")
        try RenderStageParseTests.stageWithBox.write(to: stageURL, atomically: true, encoding: .utf8)
        let outURL = dir.appendingPathComponent("out.png")

        try await NativeSceneKitRenderer().render(
            stageURL: stageURL, outputURL: outURL, cameraPath: "/AgentCam_persp", size: 256)

        let data = try Data(contentsOf: outURL)
        #expect(data.count > 1000)                 // a real PNG, not an empty file
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))   // PNG magic
    }
}

extension RenderStageParseTests {
    /// A stage with real box geometry so Model I/O has something to draw.
    static let stageWithBox = """
    #usda 1.0
    (
        defaultPrim = "World"
        upAxis = "Y"
    )

    def Xform "World"
    {
        def Mesh "Body"
        {
            point3f[] points = [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (-0.5, 0.5, -0.5), (-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)]
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 1, 2, 3, 5, 4, 7, 6, 4, 5, 1, 0, 6, 7, 3, 2, 4, 0, 3, 7, 1, 5, 6, 2]
            uniform token subdivisionScheme = "none"
            rel material:binding = </Looks/Gold>
        }
    }

    def Scope "Looks"
    {
        def Material "Gold"
        {
            def Shader "Surface"
            {
                token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.85, 0.72, 0.55)
            }
        }
    }

    def Camera "AgentCam_persp"
    {
        double focalLength = 35
        matrix4d xformOp:transform = ( (0.707, 0, -0.707, 0), (-0.354, 0.866, -0.354, 0), (0.612, 0.5, 0.612, 0), (1.5, 1.2, 1.5, 1) )
        uniform token[] xformOpOrder = ["xformOp:transform"]
    }
    """
}
