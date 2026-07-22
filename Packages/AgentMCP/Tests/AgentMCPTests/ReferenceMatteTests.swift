import Foundation
import SculptKit
import Testing
@testable import AgentMCP
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

/// Sculpt-accuracy P1 (#82): the matting stage and its wiring into the
/// reference-loading path. The acceptance criteria are asserted directly
/// against the P0 labelled corpus (`EvalCorpus`): produced-mask IoU ≥ 0.95 vs
/// ground truth on every entry, and the F1 raw→matted similarity swing
/// reproduced and beaten by the automatic matte.
@Suite struct ReferenceMatteTests {

    /// IoU between a produced foreground and the ground truth mask.
    static func iou(_ a: [Bool], _ b: [Bool]) -> Double {
        precondition(a.count == b.count)
        var inter = 0, union = 0
        for i in 0..<a.count {
            if a[i] || b[i] { union += 1 }
            if a[i] && b[i] { inter += 1 }
        }
        return union == 0 ? 1 : Double(inter) / Double(union)
    }

    /// Silhouette IoU an image scores against the ground-truth matte through
    /// the public metric — how the pipeline actually consumes a reference.
    static func metricIoU(_ image: RasterImage, truthMatte: RasterImage) -> Double {
        ImageSimilarity.compare(reference: image, render: truthMatte).silhouetteIoU
    }

    // MARK: - P0 acceptance criteria

    /// Acceptance #1: produced-mask IoU ≥ 0.95 vs the hand/ground-truth labels
    /// on every P0 corpus entry (raw form — opaque drifting background, the F1
    /// hard case the corner key leaks on).
    @Test func maskIoUClearsAcceptanceFloorOnP0Corpus() {
        let side = ImageSimilarity.gridSide
        for ref in EvalCorpus.benchmark(side: side) {
            let mask = ReferenceMatte.segment(ref.raw)
            let measured = Self.iou(mask.foreground, ref.trueForeground)
            #expect(measured >= 0.95, "\(ref.name): mask IoU \(measured) < 0.95")
        }
    }

    /// Acceptance #2: the raw→matted swing (F1). The automatic matte must beat
    /// the naive corner-key foreground on the corpus mean, and matting the raw
    /// photo must lift the measured silhouette IoU against the clean reference.
    @Test func matteBeatsNaiveKeyAndLiftsSimilarity() {
        let side = ImageSimilarity.gridSide
        var naiveTotal = 0.0, matteTotal = 0.0
        for ref in EvalCorpus.benchmark(side: side) {
            // Naive = the raw opaque photo straight into the metric (corner
            // colour key); matte = the same photo after the automatic matte.
            naiveTotal += Self.metricIoU(ref.raw, truthMatte: ref.matted)
            let matted = ReferenceMatte.apply(ref.raw)
            let mattedIoU = Self.metricIoU(matted, truthMatte: ref.matted)
            matteTotal += mattedIoU
            #expect(mattedIoU >= 0.95, "\(ref.name): matted IoU \(mattedIoU)")
        }
        let n = Double(EvalCorpus.specs().count)
        #expect(matteTotal / n >= 0.95)
        #expect(matteTotal / n > naiveTotal / n, "matte must beat the corner key")
    }

    // MARK: - Core algorithm units

    /// Solid colour over a *drifting* background (the corner-key killer): the
    /// planar background model tracks the gradient and keys the square exactly.
    @Test func planarModelTracksGradientBackground() {
        let dim = 48
        var rgba = [UInt8](repeating: 0, count: dim * dim * 4)
        for y in 0..<dim {
            for x in 0..<dim {
                let i = (y * dim + x) * 4
                let inSquare = x >= 12 && x < 36 && y >= 12 && y < 36
                if inSquare {
                    rgba[i] = 40; rgba[i + 1] = 160; rgba[i + 2] = 60
                } else {
                    let drift = UInt8(min(255, 100 + (x + y)))
                    rgba[i] = drift; rgba[i + 1] = drift; rgba[i + 2] = min(255, drift &+ 10)
                }
                rgba[i + 3] = 255
            }
        }
        let image = RasterImage(width: dim, height: dim, rgba: rgba)!
        let fg = ReferenceMatte.segment(image).foreground
        var truth = [Bool](repeating: false, count: dim * dim)
        for y in 12..<36 { for x in 12..<36 { truth[y * dim + x] = true } }
        #expect(Self.iou(fg, truth) >= 0.9)
    }

    /// Interior holes that are genuinely background-coloured must survive the
    /// matte (an annulus keeps its hole) — the property the old scanline fill
    /// destroyed and the F2 metric fix depends on.
    @Test func matteKeepsGenuineInteriorHoles() {
        let side = ImageSimilarity.gridSide
        let ring = EvalCorpus.benchmark(side: side).first { $0.name == "ring" }!
        let fg = ReferenceMatte.segment(ring.raw).foreground
        // Centre of the annulus is background in truth and must stay background.
        let centre = (side / 2) * side + side / 2
        #expect(fg[centre] == false)
        #expect(Self.iou(fg, ring.trueForeground) >= 0.95)
    }

    @Test func workingSizeCapsLongestSideAndPassesSmallImagesThrough() {
        #expect(ReferenceMatte.workingSize(width: 64, height: 64, maxSide: 512) == .init(w: 64, h: 64))
        let capped = ReferenceMatte.workingSize(width: 2048, height: 1024, maxSide: 512)
        #expect(capped == .init(w: 512, h: 256))
        // Extreme aspect ratio: the short side clamps to ≥ 1.
        let sliver = ReferenceMatte.workingSize(width: 4000, height: 1, maxSide: 512)
        #expect(sliver.w == 512 && sliver.h == 1)
    }

    /// A large image is matted at working resolution and the alpha upsampled
    /// back to native size — same result shape, capped cost.
    @Test func segmentDownsamplesLargeImages() {
        let dim = 96
        var rgba = [UInt8](repeating: 0, count: dim * dim * 4)
        for y in 0..<dim {
            for x in 0..<dim {
                let i = (y * dim + x) * 4
                let inSquare = x >= 24 && x < 72 && y >= 24 && y < 72
                rgba[i] = inSquare ? 30 : 200
                rgba[i + 1] = inSquare ? 150 : 200
                rgba[i + 2] = inSquare ? 40 : 210
                rgba[i + 3] = 255
            }
        }
        let image = RasterImage(width: dim, height: dim, rgba: rgba)!
        let mask = ReferenceMatte.segment(image, options: .init(workingMaxSide: 32))
        #expect(mask.width == dim && mask.height == dim)
        var truth = [Bool](repeating: false, count: dim * dim)
        for y in 24..<72 { for x in 24..<72 { truth[y * dim + x] = true } }
        #expect(Self.iou(mask.foreground, truth) >= 0.85)
    }

    @Test func optionsClampDegenerateValues() {
        let opts = ReferenceMatte.Options(workingMaxSide: 0, borderInset: 0, baseThreshold: -1, noiseSigma: -1)
        #expect(opts.workingMaxSide == 1)
        #expect(opts.borderInset == 1)
        #expect(opts.baseThreshold == 0)
        #expect(opts.noiseSigma == 0)
    }

    @Test func hasMeaningfulAlphaDistinguishesOpaqueImages() {
        let opaque = RasterImage(width: 1, height: 1, rgba: [1, 2, 3, 255])!
        let cut = RasterImage(width: 1, height: 1, rgba: [1, 2, 3, 0])!
        #expect(ReferenceMatte.hasMeaningfulAlpha(opaque) == false)
        #expect(ReferenceMatte.hasMeaningfulAlpha(cut) == true)
    }

    @Test func maskForegroundThresholdsAlpha() {
        let mask = ReferenceMatte.Mask(width: 2, height: 1, alpha: [0, 255])
        #expect(mask.foreground == [false, true])
    }

    /// A singular plane system (no positional spread) returns nil and the fit
    /// falls back to the border-mean constant model.
    @Test func solvePlaneRejectsSingularSystems() {
        let samples = Array(repeating: ((nx: 0.5, ny: 0.5), 0.7), count: 5)
        #expect(ReferenceMatte.solvePlane(samples) == nil)

        // 1×N image: every border sample shares nx → singular → mean fallback.
        let rgb = [(r: Double, g: Double, b: Double)](repeating: (0.5, 0.5, 0.5), count: 4)
        let model = ReferenceMatte.fitBackgroundPlane(rgb: rgb, width: 1, height: 4, inset: 1)
        #expect(model.coeff[0].ax == 0 && model.coeff[0].ay == 0)
        #expect(abs(model.coeff[0].b - 0.5) < 1e-9)
        #expect(model.residualMean < 1e-9)
    }

    @Test func solvePlaneRecoversAnExactPlane() throws {
        // v = 0.2·nx + 0.1·ny + 0.3 sampled at non-degenerate positions.
        let positions: [(nx: Double, ny: Double)] = [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9), (0.5, 0.3)]
        let samples = positions.map { ($0, 0.2 * $0.nx + 0.1 * $0.ny + 0.3) }
        let fit = try #require(ReferenceMatte.solvePlane(samples))
        #expect(abs(fit.ax - 0.2) < 1e-9)
        #expect(abs(fit.ay - 0.1) < 1e-9)
        #expect(abs(fit.b - 0.3) < 1e-9)
    }

    @Test func morphologyOpensSpecksAndClosesPinholes() {
        let w = 7, h = 7
        // A lone speck vanishes under opening.
        var speck = [Bool](repeating: false, count: w * h)
        speck[3 * w + 3] = true
        #expect(ReferenceMatte.open(speck, width: w, height: h).allSatisfy { !$0 })

        // A solid block with a single-pixel pinhole is healed by closing.
        var block = [Bool](repeating: true, count: w * h)
        block[3 * w + 3] = false
        let closed = ReferenceMatte.close(block, width: w, height: h)
        #expect(closed[3 * w + 3] == true)

        // Erosion of an all-set block clears the border (out-of-bounds counts
        // as background); dilation of a point grows a 3×3 patch.
        let eroded = ReferenceMatte.erode(block, width: w, height: h)
        #expect(eroded[0] == false)
        var point = [Bool](repeating: false, count: w * h)
        point[3 * w + 3] = true
        let dilated = ReferenceMatte.dilate(point, width: w, height: h)
        #expect(dilated[2 * w + 2] && dilated[4 * w + 4] && !dilated[0])
    }

    @Test func largestComponentKeepsBiggestAndHandlesEmpty() {
        let w = 8, h = 3
        var src = [Bool](repeating: false, count: w * h)
        // Component A: 2 pixels. Component B: 4 pixels (kept).
        src[0] = true; src[1] = true
        src[2 * w + 4] = true; src[2 * w + 5] = true; src[2 * w + 6] = true; src[2 * w + 7] = true
        let kept = ReferenceMatte.largestComponent(src, width: w, height: h)
        #expect(kept[0] == false && kept[1] == false)
        #expect(kept[2 * w + 4] && kept[2 * w + 7])

        let empty = [Bool](repeating: false, count: w * h)
        #expect(ReferenceMatte.largestComponent(empty, width: w, height: h) == empty)
    }

    @Test func upsampleAlphaMapsNearestNeighbour() {
        // 2×1 mask → 4×2 alpha: left half background, right half foreground.
        let alpha = ReferenceMatte.upsampleAlpha([false, true], fromWidth: 2, fromHeight: 1, toWidth: 4, toHeight: 2)
        #expect(alpha == [0, 0, 255, 255, 0, 0, 255, 255])
    }

    // MARK: - RasterLoader wiring

    /// The matting policy: alpha-bearing references pass through untouched; an
    /// opaque reference is matted; a matte with no foreground falls back raw.
    @Test func mattedReferencePolicy() {
        // Already has alpha → untouched.
        let cut = RasterImage(width: 2, height: 1, rgba: [9, 9, 9, 255, 9, 9, 9, 0])!
        #expect(RasterLoader.mattedReference(cut) == cut)

        // Flat opaque image → matte finds nothing → falls back to raw pixels.
        let flat = RasterImage(width: 4, height: 4, rgba: [UInt8](repeating: 128, count: 64))!
        #expect(RasterLoader.mattedReference(flat) == flat)

        // Opaque photo with a distinct subject → alpha channel now carries the
        // matte (some background pixel went transparent).
        let side = ImageSimilarity.gridSide
        let car = EvalCorpus.benchmark(side: side).first { $0.name == "car" }!
        let matted = RasterLoader.mattedReference(car.raw)
        #expect(matted != car.raw)
        #expect(ReferenceMatte.hasMeaningfulAlpha(matted))
        #expect(Self.metricIoU(matted, truthMatte: car.matted) >= 0.95)
    }

    #if canImport(ImageIO)
    /// End-to-end through the file path: an opaque raw-photo PNG reference is
    /// matted by `loadReference`, and `similarity` therefore measures the
    /// subject rather than the background (the F1 fix, live in the pipeline).
    @Test func loadReferenceMattesOpaquePNG() throws {
        let dir = Fixtures.tempDirectory()
        let refURL = dir.appendingPathComponent("raw-photo.png")
        let renderURL = dir.appendingPathComponent("render.png")
        let dim = 64
        // Reference: green square over a drifting opaque background.
        SculptVerifiableFidelityTests.writePNG(refURL, dim: dim) { x, y in
            let inSquare = x >= 16 && x < 48 && y >= 16 && y < 48
            if inSquare { return (40, 160, 60, 255) }
            let drift = UInt8(min(200, 80 + x + y))
            return (drift, drift, drift, 255)
        }
        // Render: the same square as a clean alpha matte.
        SculptVerifiableFidelityTests.writePNG(renderURL, dim: dim) { x, y in
            let inSquare = x >= 16 && x < 48 && y >= 16 && y < 48
            return inSquare ? (40, 160, 60, 255) : (0, 0, 0, 0)
        }

        let loaded = try #require(RasterLoader.loadReference(path: refURL.path))
        #expect(ReferenceMatte.hasMeaningfulAlpha(loaded))

        let report = try #require(RasterLoader.similarity(referencePath: refURL.path, renderPath: renderURL.path))
        #expect(report.silhouetteIoU >= 0.9)

        #expect(RasterLoader.loadReference(path: "/definitely-missing.png") == nil)
    }
    #endif
}
