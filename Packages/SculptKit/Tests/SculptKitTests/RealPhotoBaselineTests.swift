import Testing
import Foundation
@testable import SculptKit

@Suite("Sculpt-accuracy P0 follow-up (#94) — real-photo baseline infra")
struct RealPhotoBaselineTests {

    // MARK: - fixtures helpers

    /// A tiny 2×2 solid image; every pixel `(r,g,b,255)`.
    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RasterImage {
        var px: [UInt8] = []
        for _ in 0..<4 { px += [r, g, b, 255] }
        return RasterImage(width: 2, height: 2, rgba: px)!
    }

    /// Build a fully-reproducible fixture whose baseline expectations are set to
    /// the metric's own measurements (self-consistent, never the §2 numbers), so
    /// `reproduce` lands within tolerance. `corrupt` offsets one expectation to
    /// drive the out-of-tolerance branch.
    static func syntheticFixture(corrupt: Bool) -> RealPhotoFixture {
        let photo = solid(200, 40, 40)
        let render = solid(210, 50, 45)
        // Hand mask: opaque foreground everywhere.
        let mask = [UInt8](repeating: 255, count: 4)
        let matteRef = try! RealPhotoBaseline.matte(photo: photo, maskAlpha: mask)

        let rawMeasured = ImageSimilarity.compare(reference: photo, render: render)
        let matteMeasured = ImageSimilarity.compare(reference: matteRef, render: render)

        let rawBaseline = PassBaseline(
            id: "raw", referenceForm: .raw,
            aggregate: corrupt ? rawMeasured.aggregate + 0.5 : rawMeasured.aggregate,
            silhouetteIoU: rawMeasured.silhouetteIoU,
            ssim: rawMeasured.ssim,
            luminance: rawMeasured.luminanceCorrelation,
            tolerance: 0.001)
        // A matte pass with no component expectations (exercises the nil branch).
        let matteBaseline = PassBaseline(
            id: "matte", referenceForm: .matte,
            aggregate: matteMeasured.aggregate, tolerance: 0.001)

        return RealPhotoFixture(
            name: "synthetic",
            pose: RecordedPose(azimuthDegrees: 12, elevationDegrees: 3),
            width: 2, height: 2,
            referenceBase64: RealPhotoBaseline.encodeRGBA(photo.rgba),
            handMaskBase64: Data(mask).base64EncodedString(),
            passes: [
                PassRender(baseline: rawBaseline, renderBase64: RealPhotoBaseline.encodeRGBA(render.rgba)),
                PassRender(baseline: matteBaseline, renderBase64: RealPhotoBaseline.encodeRGBA(render.rgba)),
            ])
    }

    // MARK: - pixel codec

    @Test func decodeRoundTrips() throws {
        let img = Self.solid(1, 2, 3)
        let b64 = RealPhotoBaseline.encodeRGBA(img.rgba)
        let back = try RealPhotoBaseline.decodeRGBA(b64, width: 2, height: 2)
        #expect(back == img)
    }

    @Test func decodeRejectsNonBase64() {
        #expect(throws: RealPhotoBaseline.FixtureError.self) {
            try RealPhotoBaseline.decodeRGBA("@@@@ not base64", width: 2, height: 2)
        }
    }

    @Test func decodeRejectsWrongByteCount() {
        let b64 = Data([1, 2, 3]).base64EncodedString()
        #expect(throws: RealPhotoBaseline.FixtureError.self) {
            try RealPhotoBaseline.decodeRGBA(b64, width: 2, height: 2)
        }
    }

    // MARK: - matte

    @Test func matteAppliesMaskAlpha() throws {
        let photo = Self.solid(10, 20, 30)
        let matte = try RealPhotoBaseline.matte(photo: photo, maskAlpha: [255, 0, 255, 0])
        #expect(matte.rgba[3] == 255)   // pixel 0 foreground
        #expect(matte.rgba[7] == 0)     // pixel 1 background
        #expect(matte.rgba[0] == 10)    // colour preserved
    }

    @Test func matteRejectsWrongMaskLength() {
        #expect(throws: RealPhotoBaseline.FixtureError.self) {
            try RealPhotoBaseline.matte(photo: Self.solid(0, 0, 0), maskAlpha: [255])
        }
    }

    // MARK: - reference forms

    @Test func referenceRawAndMatte() throws {
        let f = Self.syntheticFixture(corrupt: false)
        let raw = try RealPhotoBaseline.reference(f, form: .raw)
        let matte = try RealPhotoBaseline.reference(f, form: .matte)
        #expect(raw.width == 2 && matte.width == 2)
        #expect(raw.rgba[3] == 255)   // raw keeps original opaque alpha
    }

    @Test func referenceThrowsForBlueprint() {
        let blueprint = RealPhotoFixture(
            name: "bp", pose: RecordedPose(azimuthDegrees: 0, elevationDegrees: 0),
            width: 0, height: 0, passes: [])
        #expect(throws: RealPhotoBaseline.FixtureError.self) {
            try RealPhotoBaseline.reference(blueprint, form: .raw)
        }
    }

    @Test func referenceThrowsForNonBase64Mask() {
        let f = RealPhotoFixture(
            name: "x", pose: RecordedPose(azimuthDegrees: 0, elevationDegrees: 0),
            width: 2, height: 2,
            referenceBase64: RealPhotoBaseline.encodeRGBA(Self.solid(0, 0, 0).rgba),
            handMaskBase64: "@@@@ bad",
            passes: [])
        #expect(throws: RealPhotoBaseline.FixtureError.self) {
            try RealPhotoBaseline.reference(f, form: .matte)
        }
    }

    // MARK: - near

    @Test func nearHandlesNilAndBands() {
        #expect(RealPhotoBaseline.near(0.5, nil, 0.01))            // unrecorded → pass
        #expect(RealPhotoBaseline.near(0.500, 0.505, 0.01))        // inside band
        #expect(!RealPhotoBaseline.near(0.5, 0.7, 0.01))           // outside band
    }

    // MARK: - reproduce

    @Test func reproducesWithinToleranceForConsistentFixture() throws {
        let outcome = try RealPhotoBaseline.reproduce(Self.syntheticFixture(corrupt: false))
        #expect(!outcome.pending)
        #expect(outcome.results.count == 2)
        let allWithin = outcome.results.allSatisfy(\.withinTolerance)
        #expect(allWithin)
        #expect(abs(outcome.results[0].aggregateDelta) < 0.001)
    }

    @Test func reproduceFlagsOutOfTolerance() throws {
        let outcome = try RealPhotoBaseline.reproduce(Self.syntheticFixture(corrupt: true))
        #expect(!outcome.results[0].withinTolerance)   // aggregate offset by 0.5
    }

    @Test func reproduceReportsBlueprintAsPending() throws {
        let blueprint = RealPhotoFixture(
            name: "bp", pose: RecordedPose(azimuthDegrees: 0, elevationDegrees: 0),
            width: 0, height: 0,
            passes: [PassRender(baseline: PassBaseline(id: "p", referenceForm: .matte, aggregate: 0.4))])
        let outcome = try RealPhotoBaseline.reproduce(blueprint)
        #expect(outcome.pending)
        #expect(outcome.results.isEmpty)
        #expect(!blueprint.isReproducible)
    }

    // MARK: - disk

    @Test func loadDiscoverAndReproduceAllRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("realphoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try JSONEncoder().encode(Self.syntheticFixture(corrupt: false))
        try data.write(to: dir.appendingPathComponent("synthetic.json"))
        // A non-JSON file must be ignored by discovery.
        try Data("noise".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let urls = RealPhotoBaseline.discover(in: dir)
        #expect(urls.count == 1)

        let loaded = try RealPhotoBaseline.load(from: urls[0])
        #expect(loaded.name == "synthetic")

        let outcomes = try RealPhotoBaseline.reproduceAll(in: dir)
        #expect(outcomes.count == 1)
        let allWithin = outcomes[0].results.allSatisfy(\.withinTolerance)
        #expect(allWithin)
    }

    @Test func discoverMissingDirectoryIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(RealPhotoBaseline.discover(in: missing).isEmpty)
    }

    // MARK: - committed blueprint (the §2 targets, honestly pending pixels)

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealPhoto", isDirectory: true)
    }

    @Test func blueprintFreezesSection2Targets() throws {
        let url = Self.fixturesDir.appendingPathComponent("aventador.blueprint.json")
        let bp = try RealPhotoBaseline.load(from: url)
        #expect(!bp.isReproducible)   // no pixels committed yet → pending, not faked

        func aggregate(_ id: String) -> Double? {
            bp.passes.first { $0.baseline.id == id }?.baseline.aggregate
        }
        // The frozen §2 numbers to reproduce once a real asset lands.
        #expect(aggregate("blockout-raw") == 0.170)
        #expect(aggregate("blockout-matte") == 0.348)
        #expect(aggregate("structural") == 0.483)
        #expect(aggregate("material") == 0.411)
    }

    @Test func committedRealFixturesReproduceWithinTolerance() throws {
        // Picks up any *reproducible* real fixture committed alongside the
        // blueprint and asserts ±0.01. Vacuously true while only the pending
        // blueprint is present — documented, never fabricated.
        for outcome in try RealPhotoBaseline.reproduceAll(in: Self.fixturesDir) {
            if outcome.pending { continue }
            let allWithin = outcome.results.allSatisfy(\.withinTolerance)
            #expect(allWithin, "real fixture \(outcome.name) drifted from its frozen §2 baseline")
        }
    }
}
