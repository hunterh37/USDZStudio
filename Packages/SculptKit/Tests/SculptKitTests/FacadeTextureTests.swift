import XCTest
@testable import SculptKit

final class FacadeTextureTests: XCTestCase {

    // MARK: - Generation

    func testGeneratesSquareBufferAtRequestedResolution() {
        let spec = FacadeTexture(rows: 4, columns: 3, resolution: 128)
        let maps = FacadeTextureGenerator.generate(spec)
        XCTAssertEqual(maps.albedo.width, 128)
        XCTAssertEqual(maps.albedo.height, 128)
        XCTAssertEqual(maps.albedo.rgba.count, 128 * 128 * 4)
        XCTAssertEqual(maps.emissive.width, 128)
        XCTAssertEqual(maps.emissive.rgba.count, 128 * 128 * 4)
    }

    func testDeterministicForSameSeed() {
        let spec = FacadeTexture(rows: 8, columns: 8, litFraction: 0.5, seed: 42, resolution: 64)
        let a = FacadeTextureGenerator.generate(spec)
        let b = FacadeTextureGenerator.generate(spec)
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedChangesLitPattern() {
        let base = FacadeTexture(rows: 8, columns: 8, litFraction: 0.5, seed: 1, resolution: 64)
        var other = base; other.seed = 2
        XCTAssertNotEqual(FacadeTextureGenerator.generate(base).emissive,
                          FacadeTextureGenerator.generate(other).emissive)
    }

    func testFullyLitHasEmissivePixels() {
        let spec = FacadeTexture(rows: 4, columns: 4, litFraction: 1.0,
                                 litColor: [1, 1, 1], seed: 0, resolution: 64)
        let maps = FacadeTextureGenerator.generate(spec)
        // At least one emissive channel byte is non-zero somewhere.
        let anyLit = stride(from: 0, to: maps.emissive.rgba.count, by: 4).contains {
            maps.emissive.rgba[$0] > 0 || maps.emissive.rgba[$0 + 1] > 0 || maps.emissive.rgba[$0 + 2] > 0
        }
        XCTAssertTrue(anyLit)
    }

    func testUnlitHasNoEmissivePixels() {
        let spec = FacadeTexture(rows: 4, columns: 4, litFraction: 0.0, seed: 0, resolution: 64)
        let maps = FacadeTextureGenerator.generate(spec)
        let anyLit = stride(from: 0, to: maps.emissive.rgba.count, by: 4).contains {
            maps.emissive.rgba[$0] > 0 || maps.emissive.rgba[$0 + 1] > 0 || maps.emissive.rgba[$0 + 2] > 0
        }
        XCTAssertFalse(anyLit)
        // Emissive alpha is still opaque everywhere.
        XCTAssertTrue(stride(from: 3, to: maps.emissive.rgba.count, by: 4).allSatisfy { maps.emissive.rgba[$0] == 255 })
    }

    func testClampsOutOfRangeResolutionAndCounts() {
        // Tiny resolution + absurd window counts + out-of-range litFraction/colours
        // must clamp rather than trap or overflow.
        let spec = FacadeTexture(rows: 100_000, columns: -5, litFraction: 5,
                                 wallColor: [2, -1, 0.5], windowColor: [0], litColor: [1, 1, 1, 1],
                                 seed: 7, resolution: 4)
        let maps = FacadeTextureGenerator.generate(spec)
        XCTAssertEqual(maps.albedo.width, FacadeTextureGenerator.resolutionRange.lowerBound)
        XCTAssertGreaterThan(maps.albedo.rgba.count, 0)
    }

    func testDegenerateCellSkipsWindows() {
        // More columns than pixels → window rects collapse (x1 <= x0) and are
        // skipped, leaving a pure wall.
        let spec = FacadeTexture(rows: 200, columns: 200, litFraction: 1, resolution: 16)
        let maps = FacadeTextureGenerator.generate(spec)
        XCTAssertEqual(maps.albedo.width, 16)
    }

    // MARK: - Spec model

    func testMaterialSpecFacadeRoundTripsThroughCoding() throws {
        let facade = FacadeTexture(rows: 6, columns: 5, litFraction: 0.4, seed: 9)
        let mat = MaterialSpec(id: "tower", baseColor: [0.2, 0.2, 0.2], facade: facade)
        XCTAssertTrue(mat.hasFacade)
        let data = try JSONEncoder().encode(mat)
        let decoded = try JSONDecoder().decode(MaterialSpec.self, from: data)
        XCTAssertEqual(decoded.facade, facade)
        XCTAssertTrue(decoded.hasFacade)
    }

    func testMaterialWithoutFacadeDecodesNil() throws {
        let json = #"{"id":"x","baseColor":[0.1,0.1,0.1]}"#.data(using: .utf8)!
        let mat = try JSONDecoder().decode(MaterialSpec.self, from: json)
        XCTAssertNil(mat.facade)
        XCTAssertFalse(mat.hasFacade)
    }

    func testFacadeDecodesDefaults() throws {
        let json = #"{"rows":3,"columns":4}"#.data(using: .utf8)!
        let facade = try JSONDecoder().decode(FacadeTexture.self, from: json)
        XCTAssertEqual(facade.rows, 3)
        XCTAssertEqual(facade.columns, 4)
        XCTAssertEqual(facade.litFraction, 0.35, accuracy: 1e-9)
        XCTAssertEqual(facade.resolution, 256)
        XCTAssertEqual(facade.seed, 0)
    }

    // MARK: - Validation

    func testValidFacadeHasNoIssues() {
        let facade = FacadeTexture(rows: 4, columns: 4, litFraction: 0.5, resolution: 256)
        XCTAssertTrue(SpecValidator.facadeIssues(facade, materialID: "m").isEmpty)
    }

    func testFacadeRejectsBadRowsColumns() {
        let facade = FacadeTexture(rows: 0, columns: 0)
        let issues = SpecValidator.facadeIssues(facade, materialID: "m")
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("rows/columns") })
    }

    func testFacadeRejectsBadLitFraction() {
        for value in [-0.1, 1.5, Double.nan] {
            let facade = FacadeTexture(rows: 2, columns: 2, litFraction: value)
            XCTAssertTrue(SpecValidator.facadeIssues(facade, materialID: "m")
                .contains { $0.message.contains("litFraction") })
        }
    }

    func testFacadeWarnsOnOutOfRangeResolution() {
        let facade = FacadeTexture(rows: 2, columns: 2, resolution: 9)
        let issues = SpecValidator.facadeIssues(facade, materialID: "m")
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("resolution") })
    }

    func testFacadeRejectsBadColour() {
        let facade = FacadeTexture(rows: 2, columns: 2, wallColor: [1, 1], litColor: [1, .infinity, 1])
        let issues = SpecValidator.facadeIssues(facade, materialID: "m")
        XCTAssertTrue(issues.contains { $0.message.contains("wallColor") })
        XCTAssertTrue(issues.contains { $0.message.contains("litColor") })
    }

    func testTextureIssuesSurfacesFacadeErrors() {
        let mat = MaterialSpec(id: "bad", baseColor: [0.1, 0.1, 0.1],
                               facade: FacadeTexture(rows: 0, columns: 2))
        XCTAssertFalse(SpecValidator.textureIssues(mat).isEmpty)
    }
}
