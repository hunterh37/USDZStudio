import XCTest
import simd
@testable import ViewportKit

final class DebugViewModeTests: XCTestCase {

    // MARK: Mode metadata

    func testAllModesHaveDistinctMetadata() {
        let modes = DebugViewMode.allCases
        XCTAssertEqual(modes.count, 5)
        XCTAssertEqual(Set(modes.map(\.id)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.symbol)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.label)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.helpText)).count, modes.count)
        for mode in modes {
            XCTAssertFalse(mode.symbol.isEmpty)
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.helpText.isEmpty)
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testShadedIsIdentity() {
        XCTAssertNil(DebugViewMode.shaded.materialSpec)
        XCTAssertFalse(DebugViewMode.shaded.isOverlay)
        XCTAssertFalse(DebugViewMode.shaded.replacesMaterials)
    }

    func testWireframeIsOverlayNotMaterialSwap() {
        XCTAssertTrue(DebugViewMode.wireframe.isOverlay)
        XCTAssertNil(DebugViewMode.wireframe.materialSpec)
        XCTAssertFalse(DebugViewMode.wireframe.replacesMaterials)
    }

    func testMaterialSwapModes() {
        for mode in [DebugViewMode.normals, .uvChecker, .matcap] {
            XCTAssertFalse(mode.isOverlay, "\(mode) should not be an overlay")
            XCTAssertTrue(mode.replacesMaterials, "\(mode) should replace materials")
            XCTAssertNotNil(mode.materialSpec)
        }
        XCTAssertEqual(DebugViewMode.normals.materialSpec?.kind, .normals)
        XCTAssertEqual(DebugViewMode.uvChecker.materialSpec?.kind, .uvChecker)
        XCTAssertEqual(DebugViewMode.matcap.materialSpec?.kind, .matcap)
    }

    func testMaterialLightingFlags() {
        // Normals + matcap are self-shaded (unlit); the UV checker keeps
        // lighting so surface form stays readable.
        XCTAssertTrue(DebugViewMode.normals.materialSpec?.unlit ?? false)
        XCTAssertTrue(DebugViewMode.matcap.materialSpec?.unlit ?? false)
        XCTAssertEqual(DebugViewMode.uvChecker.materialSpec?.unlit, false)
    }

    func testSpecEquatable() {
        XCTAssertEqual(DebugMaterialSpec(kind: .matcap, unlit: true),
                       DebugMaterialSpec(kind: .matcap, unlit: true))
        XCTAssertNotEqual(DebugMaterialSpec(kind: .matcap, unlit: true),
                          DebugMaterialSpec(kind: .matcap, unlit: false))
        XCTAssertNotEqual(DebugMaterialSpec(kind: .matcap, unlit: true),
                          DebugMaterialSpec(kind: .normals, unlit: true))
    }

    // MARK: Checker maths

    func testCheckerAlternates() {
        // Adjacent cells flip; diagonal cells match.
        XCTAssertTrue(DebugTextureFactory.checkerIsLight(u: 0.01, v: 0.01, squares: 8))
        XCTAssertFalse(DebugTextureFactory.checkerIsLight(u: 0.2, v: 0.01, squares: 8))
        XCTAssertFalse(DebugTextureFactory.checkerIsLight(u: 0.01, v: 0.2, squares: 8))
        XCTAssertTrue(DebugTextureFactory.checkerIsLight(u: 0.2, v: 0.2, squares: 8))
    }

    func testCheckerColorLightDarkAndGridline() {
        // Centre of the first (light) tile.
        let light = DebugTextureFactory.checkerColor(u: 1.0 / 16, v: 1.0 / 16, squares: 8)
        XCTAssertEqual(light, SIMD3<UInt8>(222, 222, 228))
        // Centre of an adjacent (dark) tile.
        let dark = DebugTextureFactory.checkerColor(u: 3.0 / 16, v: 1.0 / 16, squares: 8)
        XCTAssertEqual(dark, SIMD3<UInt8>(120, 122, 132))
        // Right on a tile border → gridline colour.
        let border = DebugTextureFactory.checkerColor(u: 0.0005, v: 1.0 / 16, squares: 8)
        XCTAssertEqual(border, SIMD3<UInt8>(60, 60, 66))
    }

    func testUVCheckerTextureShape() {
        let tex = DebugTextureFactory.uvChecker(size: 16, squares: 4)
        XCTAssertEqual(tex.width, 16)
        XCTAssertEqual(tex.height, 16)
        XCTAssertEqual(tex.rgba.count, 16 * 16 * 4)
        // Fully opaque throughout.
        for y in 0..<16 { for x in 0..<16 { XCTAssertEqual(tex.pixel(x: x, y: y).a, 255) } }
    }

    // MARK: Normal encoding

    func testNormalColorEncoding() {
        // +Z faces the camera → mid, mid, full (the classic tangent-space blue).
        let up = DebugTextureFactory.normalColor(SIMD3(0, 0, 1))
        XCTAssertEqual(up.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(up.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(up.z, 1.0, accuracy: 1e-6)
        // Negative axis clamps to 0.
        let neg = DebugTextureFactory.normalColor(SIMD3(-1, -1, -1))
        XCTAssertEqual(neg, SIMD3(0, 0, 0))
    }

    // MARK: Matcap shading

    func testMatcapShadeRange() {
        // Never below the ambient floor, never above 1.
        for nx in stride(from: Float(-1), through: 1, by: 0.25) {
            for ny in stride(from: Float(-1), through: 1, by: 0.25) {
                let s = DebugTextureFactory.matcapShade(nx: nx, ny: ny)
                XCTAssertGreaterThanOrEqual(s, 0.35 - 1e-6)
                XCTAssertLessThanOrEqual(s, 1.0 + 1e-6)
            }
        }
    }

    func testMatcapShadeBrighterTowardLight() {
        // The light comes from upper-left; a surface tilted toward it is
        // brighter than one tilted away.
        let towardLight = DebugTextureFactory.matcapShade(nx: -0.4, ny: 0.4)
        let awayFromLight = DebugTextureFactory.matcapShade(nx: 0.4, ny: -0.4)
        XCTAssertGreaterThan(towardLight, awayFromLight)
    }

    // MARK: Texture generation

    func testClayMatcapDiscAndCorners() {
        let tex = DebugTextureFactory.clayMatcap(size: 32)
        XCTAssertEqual(tex.rgba.count, 32 * 32 * 4)
        // Corner is outside the inscribed disc → transparent.
        XCTAssertEqual(tex.pixel(x: 0, y: 0).a, 0)
        // Centre is inside → opaque and grey (r == g == b).
        let centre = tex.pixel(x: 16, y: 16)
        XCTAssertEqual(centre.a, 255)
        XCTAssertEqual(centre.r, centre.g)
        XCTAssertEqual(centre.g, centre.b)
    }

    func testNormalMatcapCentreIsForwardBlue() {
        let tex = DebugTextureFactory.normalMatcap(size: 32)
        let centre = tex.pixel(x: 16, y: 16)
        XCTAssertEqual(centre.a, 255)
        // Centre normal ≈ +Z → blue dominant, r/g near mid.
        XCTAssertGreaterThan(centre.b, centre.r)
        XCTAssertGreaterThan(centre.b, centre.g)
        // Corner outside the disc is transparent.
        XCTAssertEqual(tex.pixel(x: 0, y: 0).a, 0)
    }

    func testTextureFactoryDispatch() {
        XCTAssertEqual(DebugTextureFactory.texture(for: .uvChecker, size: 8).width, 8)
        XCTAssertEqual(DebugTextureFactory.texture(for: .normals, size: 8).width, 8)
        XCTAssertEqual(DebugTextureFactory.texture(for: .matcap, size: 8).width, 8)
    }

    // MARK: Wireframe edges

    func testUniqueEdgesOfSingleTriangle() {
        let edges = WireframeGeometry.uniqueEdges(triangleIndices: [0, 1, 2])
        XCTAssertEqual(Set(edges), Set([SIMD2<UInt32>(0, 1), SIMD2(1, 2), SIMD2(0, 2)]))
    }

    func testSharedEdgeDeduplicated() {
        // Two triangles of a quad share the 1–2 edge → 5 unique edges, not 6.
        let edges = WireframeGeometry.uniqueEdges(triangleIndices: [0, 1, 2, 2, 1, 3])
        XCTAssertEqual(edges.count, 5)
        XCTAssertEqual(Set(edges), Set([
            SIMD2<UInt32>(0, 1), SIMD2(1, 2), SIMD2(0, 2), SIMD2(1, 3), SIMD2(2, 3)]))
    }

    func testEdgesNormalizeOrientation() {
        // Reversed winding yields the same ordered (low, high) edge keys.
        let edges = WireframeGeometry.uniqueEdges(triangleIndices: [2, 1, 0])
        XCTAssertEqual(Set(edges), Set([SIMD2<UInt32>(0, 1), SIMD2(1, 2), SIMD2(0, 2)]))
    }

    func testEmptyAndPartialTriangleIgnored() {
        XCTAssertTrue(WireframeGeometry.uniqueEdges(triangleIndices: []).isEmpty)
        // A trailing incomplete triangle (2 stray indices) is ignored.
        let edges = WireframeGeometry.uniqueEdges(triangleIndices: [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(edges), Set([SIMD2<UInt32>(0, 1), SIMD2(1, 2), SIMD2(0, 2)]))
    }

    // MARK: clamp helper

    func testClamp01() {
        XCTAssertEqual(clamp01(-0.5), 0)
        XCTAssertEqual(clamp01(0.5), 0.5)
        XCTAssertEqual(clamp01(1.5), 1)
    }
}
