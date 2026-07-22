import Foundation

// Sculpt-accuracy P0 follow-up (#94): real-photo baseline fixtures.
//
// PR #88 froze the *synthetic* corpus (masks and poses exact by construction).
// The §2 analysis baselines, however, came from a one-off real Aventador photo
// that was never committed (blockout raw 0.170 / matte 0.348, structural 0.483,
// material 0.411). This file is the infrastructure to slot such a real
// reference in the honest way and freeze those numbers as a regression fixture.
//
// A committed real fixture carries everything needed to *reproduce* a §2 row:
//   • the reference photo pixels,
//   • a hand-labelled foreground mask (per-pixel alpha),
//   • the recorded camera pose,
//   • the rendered model image for each pass, and
//   • the expected similarity numbers with a ±tolerance.
//
// Nothing here fabricates a photo, a hand mask, a pose, or a measured number.
// The pixel-bearing fixtures used by the tests are clearly synthetic and only
// exercise the machinery; their expectations are self-consistent (computed by
// the metric), never the §2 values. The §2 targets live in a *blueprint* that
// carries the numbers-to-hit but no pixels, and is reported as `pending` until
// a real asset is committed — so the target is frozen without being faked.

/// The camera pose recorded alongside a reference photo. Ground truth for the
/// azimuth/elevation the render must match; same convention as the turntable.
public struct RecordedPose: Sendable, Equatable, Codable {
    public var azimuthDegrees: Double
    public var elevationDegrees: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
    }
}

/// Which form of the reference a pass is scored against. The F1 finding is that
/// segmentation dominates: the same photo scores very differently raw vs matted.
public enum ReferenceForm: String, Sendable, Codable {
    /// The photo exactly as captured (opaque background included).
    case raw
    /// The photo with the hand mask applied — background made transparent.
    case matte
}

/// The frozen expectation for one pass row of the §2 table.
public struct PassBaseline: Sendable, Equatable, Codable {
    public var id: String
    public var referenceForm: ReferenceForm
    public var aggregate: Double
    /// Optional component expectations (the §2 rows that recorded them).
    public var silhouetteIoU: Double?
    public var ssim: Double?
    public var luminance: Double?
    /// Half-width of the acceptance band. §2 requires ±0.01.
    public var tolerance: Double

    public init(id: String, referenceForm: ReferenceForm, aggregate: Double,
                silhouetteIoU: Double? = nil, ssim: Double? = nil,
                luminance: Double? = nil, tolerance: Double = 0.01) {
        self.id = id
        self.referenceForm = referenceForm
        self.aggregate = aggregate
        self.silhouetteIoU = silhouetteIoU
        self.ssim = ssim
        self.luminance = luminance
        self.tolerance = tolerance
    }
}

/// One rendered pass paired with its frozen expectation. `renderBase64` is the
/// RGBA8 render pixels; absent (nil) marks the pass pending real pixels.
public struct PassRender: Sendable, Equatable, Codable {
    public var baseline: PassBaseline
    public var renderBase64: String?

    public init(baseline: PassBaseline, renderBase64: String? = nil) {
        self.baseline = baseline
        self.renderBase64 = renderBase64
    }
}

/// A committed real-photo fixture (or a pending blueprint). When pixel payloads
/// are present it fully reproduces its §2 rows; when they are absent it is a
/// blueprint recording the numbers-to-hit until a real asset is committed.
public struct RealPhotoFixture: Sendable, Equatable, Codable {
    public var name: String
    public var pose: RecordedPose
    public var width: Int
    public var height: Int
    /// Reference photo RGBA8, base64. Absent ⇒ blueprint (pending pixels).
    public var referenceBase64: String?
    /// Hand-labelled foreground mask, one alpha byte per pixel, base64.
    public var handMaskBase64: String?
    public var passes: [PassRender]

    public init(name: String, pose: RecordedPose, width: Int, height: Int,
                referenceBase64: String? = nil, handMaskBase64: String? = nil,
                passes: [PassRender]) {
        self.name = name
        self.pose = pose
        self.width = width
        self.height = height
        self.referenceBase64 = referenceBase64
        self.handMaskBase64 = handMaskBase64
        self.passes = passes
    }

    /// True when the fixture carries the pixels needed to reproduce its numbers.
    /// A blueprint (missing reference/mask) is not reproducible — it is pending.
    public var isReproducible: Bool {
        referenceBase64 != nil && handMaskBase64 != nil
            && passes.allSatisfy { $0.renderBase64 != nil }
    }
}

/// The measured outcome of reproducing one pass row.
public struct PassResult: Sendable, Equatable {
    public var id: String
    public var measured: SimilarityReport
    public var baseline: PassBaseline
    /// Every recorded component (aggregate + any present sub-metric) landed
    /// inside its ±tolerance band.
    public var withinTolerance: Bool
    /// Signed aggregate error (measured − expected).
    public var aggregateDelta: Double
}

/// The outcome of reproducing one fixture: either its per-pass results, or a
/// note that it is pending real pixels (no fabrication).
public struct FixtureOutcome: Sendable, Equatable {
    public var name: String
    public var pending: Bool
    public var results: [PassResult]
}

public enum RealPhotoBaseline {

    /// Errors distinguishing a genuinely-absent asset (fine — report pending)
    /// from a malformed one (a real problem).
    public enum FixtureError: Error, Equatable {
        case malformedPixels(String)
    }

    // MARK: - Pixel codec

    /// Decode a base64 RGBA8 payload into a `RasterImage`. Throws when the byte
    /// count does not match `width * height * 4` — a malformed committed asset.
    public static func decodeRGBA(_ base64: String, width: Int, height: Int) throws -> RasterImage {
        guard let data = Data(base64Encoded: base64) else {
            throw FixtureError.malformedPixels("not base64")
        }
        guard let image = RasterImage(width: width, height: height, rgba: [UInt8](data)) else {
            throw FixtureError.malformedPixels("byte count ≠ \(width * height * 4)")
        }
        return image
    }

    /// Encode RGBA8 bytes to base64 (used to author fixtures deterministically).
    public static func encodeRGBA(_ rgba: [UInt8]) -> String {
        Data(rgba).base64EncodedString()
    }

    // MARK: - Reference forms

    /// Apply a hand mask (one alpha byte per pixel) to a photo, producing the
    /// matte: foreground pixels keep their colour, background alpha → 0.
    public static func matte(photo: RasterImage, maskAlpha: [UInt8]) throws -> RasterImage {
        let pixelCount = photo.width * photo.height
        guard maskAlpha.count == pixelCount else {
            throw FixtureError.malformedPixels("mask length ≠ \(pixelCount)")
        }
        var out = photo.rgba
        for i in 0..<pixelCount {
            out[i * 4 + 3] = maskAlpha[i]
        }
        // Safe by construction: same dimensions and buffer length as `photo`.
        return RasterImage(width: photo.width, height: photo.height, rgba: out)!
    }

    /// The reference image in the requested form for a reproducible fixture.
    static func reference(_ fixture: RealPhotoFixture, form: ReferenceForm) throws -> RasterImage {
        guard let refB64 = fixture.referenceBase64, let maskB64 = fixture.handMaskBase64 else {
            throw FixtureError.malformedPixels("blueprint has no pixels")
        }
        let photo = try decodeRGBA(refB64, width: fixture.width, height: fixture.height)
        switch form {
        case .raw:
            return photo
        case .matte:
            guard let maskData = Data(base64Encoded: maskB64) else {
                throw FixtureError.malformedPixels("mask not base64")
            }
            return try matte(photo: photo, maskAlpha: [UInt8](maskData))
        }
    }

    // MARK: - Reproduction

    /// Reproduce every pass of one fixture. A blueprint (no pixels) returns a
    /// `pending` outcome rather than a fabricated measurement.
    public static func reproduce(_ fixture: RealPhotoFixture) throws -> FixtureOutcome {
        guard fixture.isReproducible else {
            return FixtureOutcome(name: fixture.name, pending: true, results: [])
        }
        var results: [PassResult] = []
        for pass in fixture.passes {
            let ref = try reference(fixture, form: pass.baseline.referenceForm)
            // `renderBase64` is non-nil here (isReproducible guaranteed it).
            let render = try decodeRGBA(pass.renderBase64!, width: fixture.width, height: fixture.height)
            let measured = ImageSimilarity.compare(reference: ref, render: render)
            let b = pass.baseline
            let within = near(measured.aggregate, b.aggregate, b.tolerance)
                && near(measured.silhouetteIoU, b.silhouetteIoU, b.tolerance)
                && near(measured.ssim, b.ssim, b.tolerance)
                && near(measured.luminanceCorrelation, b.luminance, b.tolerance)
            results.append(PassResult(
                id: b.id, measured: measured, baseline: b,
                withinTolerance: within,
                aggregateDelta: measured.aggregate - b.aggregate))
        }
        return FixtureOutcome(name: fixture.name, pending: false, results: results)
    }

    /// A measured value is within tolerance of an expectation. A nil expectation
    /// (the §2 row didn't record that component) is not checked → passes.
    static func near(_ measured: Double, _ expected: Double?, _ tolerance: Double) -> Bool {
        guard let expected else { return true }
        return abs(measured - expected) <= tolerance
    }

    // MARK: - Disk loading

    /// Load one fixture (or blueprint) from a JSON file.
    public static func load(from url: URL) throws -> RealPhotoFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RealPhotoFixture.self, from: data)
    }

    /// Discover fixture JSON files in a directory (sorted for determinism). A
    /// non-existent directory is a legitimately-absent asset set → empty list,
    /// never an error and never fabricated data.
    public static func discover(in directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// Load and reproduce every fixture committed in a directory. Blueprints come
    /// back as `pending`; complete fixtures come back with measured results.
    public static func reproduceAll(in directory: URL) throws -> [FixtureOutcome] {
        try discover(in: directory).map { try reproduce(try load(from: $0)) }
    }
}
