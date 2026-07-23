import XCTest
import SculptKit
@testable import AgentMCP

final class FacadeBakerTests: XCTestCase {

    // MARK: - Bake path decisions (fake writer, no disk)

    func testNoFacadeReturnsMaterialUnchanged() throws {
        let mat = MaterialSpec(id: "plain", baseColor: [0.2, 0.2, 0.2])
        var wrote = 0
        let out = try FacadeBaker.bake(mat, into: URL(fileURLWithPath: "/tmp/x")) { _, _ in wrote += 1 }
        XCTAssertEqual(out, mat)
        XCTAssertEqual(wrote, 0)
    }

    func testFacadeFillsBothMapsAndWritesTwoFiles() throws {
        let mat = MaterialSpec(id: "night tower", baseColor: [0.1, 0.1, 0.1],
                               facade: FacadeTexture(rows: 4, columns: 3))
        var written: [URL] = []
        let dir = URL(fileURLWithPath: "/tmp/facades")
        let out = try FacadeBaker.bake(mat, into: dir) { _, url in written.append(url) }
        XCTAssertEqual(written.count, 2)
        XCTAssertNotNil(out.albedoMap)
        XCTAssertNotNil(out.emissiveMap)
        // Names are sanitized from the material id.
        XCTAssertTrue(out.albedoMap!.hasSuffix("night_tower_facade_albedo.png"))
        XCTAssertTrue(out.emissiveMap!.hasSuffix("night_tower_facade_emissive.png"))
    }

    func testExplicitMapsAreNotClobbered() throws {
        let mat = MaterialSpec(id: "t", baseColor: [0.1, 0.1, 0.1],
                               albedoMap: "/custom/albedo.png",
                               emissiveMap: "/custom/emissive.png",
                               facade: FacadeTexture(rows: 2, columns: 2))
        var wrote = 0
        let out = try FacadeBaker.bake(mat, into: URL(fileURLWithPath: "/tmp")) { _, _ in wrote += 1 }
        XCTAssertEqual(out.albedoMap, "/custom/albedo.png")
        XCTAssertEqual(out.emissiveMap, "/custom/emissive.png")
        XCTAssertEqual(wrote, 0)
    }

    func testWriterErrorPropagates() {
        struct Boom: Error {}
        let mat = MaterialSpec(id: "t", baseColor: [0.1, 0.1, 0.1],
                               facade: FacadeTexture(rows: 2, columns: 2))
        XCTAssertThrowsError(try FacadeBaker.bake(mat, into: URL(fileURLWithPath: "/tmp")) { _, _ in throw Boom() })
    }

    // MARK: - Bake directory

    func testBakeDirectoryBesideStage() {
        let dir = FacadeBaker.bakeDirectory(for: URL(fileURLWithPath: "/models/city.usda"))
        XCTAssertEqual(dir.path, "/models/textures")
    }

    func testBakeDirectoryHeadlessUsesTemp() {
        let dir = FacadeBaker.bakeDirectory(for: nil)
        XCTAssertTrue(dir.path.contains("usdz-facade-"))
    }

    // MARK: - Real PNG round-trip through the ImageIO seam

    func testDefaultWriterProducesLoadablePNG() throws {
        let mat = MaterialSpec(id: "rt", baseColor: [0.1, 0.1, 0.1],
                               facade: FacadeTexture(rows: 4, columns: 4, litFraction: 1,
                                                     litColor: [1, 1, 1], resolution: 32))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("facade-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try FacadeBaker.bake(mat, into: dir)
        // Both files exist and decode back to the requested resolution.
        let albedo = try XCTUnwrap(RasterLoader.load(path: out.albedoMap!))
        XCTAssertEqual(albedo.width, 32)
        XCTAssertEqual(albedo.height, 32)
        let emissive = try XCTUnwrap(RasterLoader.load(path: out.emissiveMap!))
        XCTAssertEqual(emissive.width, 32)
    }

    func testWriterFailsWhenDestinationCannotBeCreated() {
        // Targeting an existing *directory* path makes CGImageDestination
        // creation return nil → destinationCreationFailed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("facade-dir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = FacadeTextureGenerator.generate(FacadeTexture(rows: 2, columns: 2, resolution: 16)).albedo
        XCTAssertThrowsError(try RasterPNGWriter.write(img, to: dir)) { error in
            XCTAssertEqual(error as? RasterPNGWriter.WriteError, .destinationCreationFailed)
        }
    }

    func testWriterCreatesMissingParentDirectory() throws {
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent("facade-\(UUID().uuidString)/nested/deeper")
        defer { try? FileManager.default.removeItem(at: deep.deletingLastPathComponent().deletingLastPathComponent()) }
        let img = FacadeTextureGenerator.generate(FacadeTexture(rows: 2, columns: 2, resolution: 16)).albedo
        let url = deep.appendingPathComponent("a.png")
        try RasterPNGWriter.write(img, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
