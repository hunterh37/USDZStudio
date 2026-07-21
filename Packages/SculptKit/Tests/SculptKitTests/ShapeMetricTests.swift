import Testing
import Foundation
@testable import SculptKit

@Suite("Sculpt-accuracy P2 — concavity-preserving shape metric")
struct ShapeMetricTests {

    let side = 64

    // MARK: - fixtures

    /// A concave "car": body slab + cabin, with two circular wheel gaps cut out
    /// of the underside — the interior concavities a faithful reference keeps.
    private func carMask() -> [Bool] {
        var m = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let nx = (Double(x) + 0.5) / Double(side)
                let ny = (Double(y) + 0.5) / Double(side)
                let body = ny >= 0.42 && ny <= 0.66 && nx >= 0.14 && nx <= 0.86
                let cabin = ny >= 0.30 && ny < 0.42 && nx >= 0.34 && nx <= 0.66
                let gap1 = hypot(nx - 0.30, ny - 0.66) <= 0.09
                let gap2 = hypot(nx - 0.70, ny - 0.66) <= 0.09
                m[y * side + x] = (body || cabin) && !(gap1 || gap2)
            }
        }
        return m
    }

    /// The origin-collapsed blockout blob: the solid bounding box of a mask,
    /// concavities filled in.
    private func filledBoundingBox(of mask: [Bool]) -> [Bool] {
        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side where mask[y * side + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        var out = [Bool](repeating: false, count: side * side)
        for y in minY...maxY { for x in minX...maxX { out[y * side + x] = true } }
        return out
    }

    private func shifted(_ mask: [Bool], by dx: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<side {
            for x in 0..<side {
                let sx = x - dx
                if sx >= 0, sx < side, mask[y * side + sx] { out[y * side + x] = true }
            }
        }
        return out
    }

    private func image(from mask: [Bool]) -> RasterImage {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<mask.count where mask[i] {
            rgba[i * 4] = 50; rgba[i * 4 + 1] = 150; rgba[i * 4 + 2] = 60; rgba[i * 4 + 3] = 255
        }
        return RasterImage(width: side, height: side, rgba: rgba)!
    }

    // MARK: - the acceptance criterion

    /// Reverses the F2 anomaly: with concavities preserved in the reference, the
    /// correctly-placed gapped car scores STRICTLY higher than the filled blob.
    @Test func placedGeometryBeatsBlobOnShapeTerm() {
        let car = carMask()
        let blob = filledBoundingBox(of: car)

        let placed = ShapeMetric.shapeScore(reference: car, render: car, side: side)
        let blobScore = ShapeMetric.shapeScore(reference: car, render: blob, side: side)

        #expect(placed.score > blobScore.score)
        #expect(abs(placed.score - 1) < 1e-9)   // a perfect match scores ~1
    }

    /// The old anomaly, made explicit: measured against an OVER-FILLED reference,
    /// plain IoU rewards the blob over the real car. Preserving concavities and
    /// scoring contour agreement flips it back.
    @Test func demonstratesAndReversesTheOverfillAnomaly() {
        let car = carMask()
        let blob = filledBoundingBox(of: car)
        let overFilledRef = blob   // the reference that was over-filled

        // Anomaly: against the over-filled reference, IoU alone ranks blob > car.
        let iouBlob = ShapeMetric.maskIoU(overFilledRef, blob)
        let iouCar = ShapeMetric.maskIoU(overFilledRef, car)
        #expect(iouBlob > iouCar)

        // Fix: against a concavity-preserving reference, the shape term ranks
        // the car strictly above the blob.
        let carScore = ShapeMetric.shapeScore(reference: car, render: car, side: side).score
        let blobScore = ShapeMetric.shapeScore(reference: car, render: blob, side: side).score
        #expect(carScore > blobScore)
    }

    // MARK: - monotonicity + resolution (F6)

    @Test func shapeScoreIsMonotonicInError() {
        let car = carMask()
        var previous = -1.0
        // Shrinking horizontal error must never decrease the score.
        for dx in stride(from: 16, through: 0, by: -2) {
            let score = ShapeMetric.shapeScore(reference: car, render: shifted(car, by: dx), side: side).score
            #expect(score >= previous - 1e-9)
            previous = score
        }
        #expect(abs(previous - 1) < 1e-9)   // zero error ⇒ perfect
    }

    @Test func resolutionSensitivityReported() {
        let car = carMask()
        let blob = filledBoundingBox(of: car)
        // Report the score at three resolutions; the car-vs-blob ordering must
        // hold across all of them (the fix is not a resolution artefact).
        for s in [32, 64, 128] {
            // Re-render the masks at this resolution via images so the grid
            // resamples them the way the real path would.
            let refImg = image(from: car)
            let placed = ShapeMetric.shapeScore(reference: refImg, render: refImg, side: s)
            let blobImg = image(from: blob)
            let blobScore = ShapeMetric.shapeScore(reference: refImg, render: blobImg, side: s)
            #expect(placed.score > blobScore.score)
        }
    }

    // MARK: - appearance term + image overload

    @Test func appearanceSeparatedFromShape() {
        let car = carMask()
        let refImg = image(from: car)
        // Identical images: appearance ~1.
        #expect(ShapeMetric.appearanceScore(reference: refImg, render: refImg, side: side) > 0.9)
        // The RasterImage shape overload agrees with a perfect match.
        #expect(abs(ShapeMetric.shapeScore(reference: refImg, render: refImg, side: side).score - 1) < 1e-9)
    }

    // MARK: - internals / edges

    @Test func maskIoUEdgeCases() {
        #expect(ShapeMetric.maskIoU([true], [true, false]) == 0)     // length mismatch
        #expect(ShapeMetric.maskIoU([false, false], [false, false]) == 1)  // both empty
    }

    @Test func contourAgreementEdgeCases() {
        #expect(ShapeMetric.contourAgreement([], [], side: side) == 1)
        #expect(ShapeMetric.contourAgreement([(1, 1)], [], side: side) == 0)
    }

    @Test func boundaryFindsInteriorHoleOutline() {
        // A solid square vs a ring (square with a hole): the ring has more
        // boundary cells because the interior hole contributes an outline.
        var solid = [Bool](repeating: false, count: side * side)
        for y in 20..<44 { for x in 20..<44 { solid[y * side + x] = true } }
        var ring = solid
        for y in 28..<36 { for x in 28..<36 { ring[y * side + x] = false } }
        let solidEdges = ShapeMetric.boundary(solid, side: side)
        let ringEdges = ShapeMetric.boundary(ring, side: side)
        #expect(ringEdges.count > solidEdges.count)
    }
}
