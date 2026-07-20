import XCTest
@testable import QuickLookKit

final class USDAThumbnailRendererTests: XCTestCase {

    // MARK: canPreview / supportedExtensions

    func testCanPreviewAcceptsAllSupportedExtensionsCaseInsensitive() {
        for ext in ["usd", "usda", "usdc", "usdz", "USDA", "UsdZ"] {
            XCTAssertTrue(USDAThumbnailRenderer.canPreview(
                URL(fileURLWithPath: "/tmp/model.\(ext)")), "\(ext) should preview")
        }
    }

    func testCanPreviewRejectsUnsupported() {
        XCTAssertFalse(USDAThumbnailRenderer.canPreview(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(USDAThumbnailRenderer.canPreview(URL(fileURLWithPath: "/tmp/noext")))
    }

    func testSupportedExtensions() {
        XCTAssertEqual(USDAThumbnailRenderer.supportedExtensions,
                       ["usd", "usda", "usdc", "usdz"])
    }

    // MARK: locateUsdrecord

    func testLocateUsdrecordUsesValidOverride() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: ["DICYANIN_USDRECORD": "/opt/usdrecord"],
            locatePython: { XCTFail("should not consult python"); return nil },
            fileExists: { $0 == "/opt/usdrecord" })
        XCTAssertEqual(path, "/opt/usdrecord")
    }

    func testLocateUsdrecordOverrideMissingReturnsNil() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: ["DICYANIN_USDRECORD": "/opt/gone"],
            locatePython: { "/py/bin/python" },
            fileExists: { _ in false })
        XCTAssertNil(path)
    }

    func testLocateUsdrecordEmptyOverrideFallsThroughToPython() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: ["DICYANIN_USDRECORD": ""],
            locatePython: { "/py/bin/python" },
            fileExists: { $0 == "/py/bin/usdrecord" })
        XCTAssertEqual(path, "/py/bin/usdrecord")
    }

    func testLocateUsdrecordBesidePython() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: [:],
            locatePython: { "/py/bin/python3" },
            fileExists: { $0 == "/py/bin/usdrecord" })
        XCTAssertEqual(path, "/py/bin/usdrecord")
    }

    func testLocateUsdrecordNoPython() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: [:],
            locatePython: { nil },
            fileExists: { _ in true })
        XCTAssertNil(path)
    }

    func testLocateUsdrecordPythonButNoNeighborBinary() {
        let path = USDAThumbnailRenderer.locateUsdrecord(
            environment: [:],
            locatePython: { "/py/bin/python3" },
            fileExists: { _ in false })
        XCTAssertNil(path)
    }

    // MARK: renderPlan

    func testRenderPlanProducesUsdrecordInvocation() throws {
        let plan = try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/chair.usdz"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 512,
            usdrecord: "/py/bin/usdrecord")
        XCTAssertEqual(plan, USDAThumbnailRenderer.RenderPlan(
            usdrecord: "/py/bin/usdrecord",
            arguments: ["--imageWidth", "512", "/models/chair.usdz", "/tmp/out.png"],
            outputPath: "/tmp/out.png"))
    }

    func testRenderPlanStandardizesSourcePath() throws {
        let plan = try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/../models/chair.usda"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 256,
            usdrecord: "/bin/usdrecord")
        XCTAssertEqual(plan.arguments[2], "/models/chair.usda")
    }

    func testRenderPlanRejectsUnsupportedExtension() {
        XCTAssertThrowsError(try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/photo.png"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 512,
            usdrecord: "/bin/usdrecord")) { error in
            XCTAssertEqual(error as? USDAThumbnailRenderer.PlanError,
                           .unsupportedExtension("png"))
        }
    }

    func testRenderPlanRejectsNonPositiveSize() {
        XCTAssertThrowsError(try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/a.usdz"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 0,
            usdrecord: "/bin/usdrecord")) { error in
            XCTAssertEqual(error as? USDAThumbnailRenderer.PlanError, .invalidSize(0))
        }
    }

    func testRenderPlanRejectsMissingUsdrecordNil() {
        XCTAssertThrowsError(try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/a.usdz"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 512,
            usdrecord: nil)) { error in
            XCTAssertEqual(error as? USDAThumbnailRenderer.PlanError, .usdrecordNotFound)
        }
    }

    func testRenderPlanRejectsEmptyUsdrecord() {
        XCTAssertThrowsError(try USDAThumbnailRenderer.renderPlan(
            source: URL(fileURLWithPath: "/models/a.usdz"),
            outputPath: "/tmp/out.png",
            maximumPixelSize: 512,
            usdrecord: "")) { error in
            XCTAssertEqual(error as? USDAThumbnailRenderer.PlanError, .usdrecordNotFound)
        }
    }

    // MARK: temporaryOutputPath

    func testTemporaryOutputPathUsesSourceName() {
        let path = USDAThumbnailRenderer.temporaryOutputPath(
            for: URL(fileURLWithPath: "/models/chair.usdz"),
            token: "abc123",
            temporaryDirectory: URL(fileURLWithPath: "/var/tmp"))
        XCTAssertEqual(path, "/var/tmp/chair.abc123.png")
    }

    func testTemporaryOutputPathForNestedSource() {
        let path = USDAThumbnailRenderer.temporaryOutputPath(
            for: URL(fileURLWithPath: "/a/b/scene.usda"),
            token: "tok",
            temporaryDirectory: URL(fileURLWithPath: "/var/tmp"))
        XCTAssertEqual(path, "/var/tmp/scene.tok.png")
    }

    // MARK: RenderPlan value semantics

    func testRenderPlanInitAndEquality() {
        let a = USDAThumbnailRenderer.RenderPlan(
            usdrecord: "/u", arguments: ["x"], outputPath: "/o")
        let b = USDAThumbnailRenderer.RenderPlan(
            usdrecord: "/u", arguments: ["x"], outputPath: "/o")
        XCTAssertEqual(a, b)
    }
}
