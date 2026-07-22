import Foundation
import SculptKit

// Sculpt-accuracy P1 (#82): robust reference segmentation (matting).
//
// Finding F1 (`specs/sculpt-accuracy-analysis.md`): segmentation dominates
// reconstruction error — the same Aventador photo scored silhouette-IoU 0.166
// raw vs 0.420 matted, a 2.5× swing driven purely by how the foreground is
// isolated. The old colour-threshold heuristic (green-hue ∪ dark, largest
// connected component, morphological close / scanline fill) leaked background
// greens and over-filled rooflines because it keyed a *single* corner colour
// and assumed a flat background.
//
// Approaches considered (spec P1): GrabCut (GMM + graph cut), saliency + guided
// filter, and a learned matte. A learned matte pulls in weights/runtime; a full
// GrabCut graph-cut is a lot of surface to hold at the 100% coverage floor for
// a deterministic transform. The chosen algorithm is a **border-prior
// background model + residual keying + morphological clean-up + connected
// components** — the deterministic, dependency-free core the other two share:
//
//   1. Fit a *spatially varying* (planar, per-channel) model of the background
//      colour from a border ring. A single mean colour cannot track a gradient
//      background (sky→road, vignetting); a plane fit tracks the smooth drift
//      that made the old corner-key leak, and predicts the background colour at
//      every interior pixel.
//   2. Classify a pixel as foreground when its colour residual from the
//      predicted background exceeds an adaptive threshold derived from the
//      border residual statistics (so a noisy background raises the bar).
//   3. Morphological open then close (3×3) removes specks and pinholes without
//      filling genuine interior holes (wheel gaps, an annulus centre) — those
//      are background-coloured and survive the colour key.
//   4. Keep the largest 4-connected foreground component to drop stray islands.
//
// This lives in AgentMCP (the executor/imaging layer, beside `RasterLoader`) so
// SculptKit stays pixel-decode-free (program guardrail). It operates on decoded
// `RasterImage` RGBA arrays — pure array math, no imaging framework — and is
// therefore fully unit-testable against the SculptKit P0 corpus.
public enum ReferenceMatte {

    /// Tunables for the matte. Defaults are chosen to clear the P0 acceptance
    /// (produced-mask IoU ≥ 0.95) without being fit to any single reference.
    public struct Options: Sendable, Equatable {
        /// Longest working-resolution side. Real photos are huge (5472×3648);
        /// the downstream metric resamples to 64×64 anyway, so the matte is
        /// computed at a capped resolution and the alpha upsampled back.
        public var workingMaxSide: Int
        /// Thickness of the border ring (in working pixels) used as the
        /// background prior.
        public var borderInset: Int
        /// Floor on the foreground colour-distance threshold (an RGB Euclidean
        /// distance over 0…1 channels). Guards against a near-zero adaptive
        /// threshold on a perfectly flat background.
        public var baseThreshold: Double
        /// Multiplier on the border residual standard deviation folded into the
        /// adaptive threshold.
        public var noiseSigma: Double

        public init(workingMaxSide: Int = 512, borderInset: Int = 2,
                    baseThreshold: Double = 0.12, noiseSigma: Double = 3.0) {
            self.workingMaxSide = max(1, workingMaxSide)
            self.borderInset = max(1, borderInset)
            self.baseThreshold = max(0, baseThreshold)
            self.noiseSigma = max(0, noiseSigma)
        }
    }

    /// A binary foreground matte at the source image's native resolution: one
    /// alpha byte per pixel (0 = background, 255 = foreground).
    public struct Mask: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var alpha: [UInt8]

        public init(width: Int, height: Int, alpha: [UInt8]) {
            self.width = width
            self.height = height
            self.alpha = alpha
        }

        /// The mask as a `[Bool]` foreground field (255 → true).
        public var foreground: [Bool] { alpha.map { $0 > 127 } }
    }

    // MARK: - Public entry points

    /// Segment an opaque reference photo into a binary foreground matte.
    public static func segment(_ image: RasterImage, options: Options = Options()) -> Mask {
        let work = workingSize(width: image.width, height: image.height, maxSide: options.workingMaxSide)
        let rgb = sampleRGB(image, toWidth: work.w, toHeight: work.h)

        let model = fitBackgroundPlane(rgb: rgb, width: work.w, height: work.h, inset: options.borderInset)
        var fg = classify(rgb: rgb, width: work.w, height: work.h, model: model,
                          baseThreshold: options.baseThreshold, noiseSigma: options.noiseSigma)
        fg = open(fg, width: work.w, height: work.h)
        fg = close(fg, width: work.w, height: work.h)
        fg = largestComponent(fg, width: work.w, height: work.h)

        let alpha = upsampleAlpha(fg, fromWidth: work.w, fromHeight: work.h,
                                  toWidth: image.width, toHeight: image.height)
        return Mask(width: image.width, height: image.height, alpha: alpha)
    }

    /// Return a copy of `image` with the segmented matte written into its alpha
    /// channel — the "matte" reference form the metric prefers. Background
    /// pixels become fully transparent; foreground keeps its colour, opaque.
    public static func apply(_ image: RasterImage, options: Options = Options()) -> RasterImage {
        let mask = segment(image, options: options)
        var out = image.rgba
        let count = image.width * image.height
        for i in 0..<count {
            out[i * 4 + 3] = mask.alpha[i]
        }
        // Safe: identical dimensions and buffer length to `image`.
        return RasterImage(width: image.width, height: image.height, rgba: out)!
    }

    /// True when the image already carries a usable alpha channel (at least one
    /// non-opaque pixel) — in which case it needs no matting.
    public static func hasMeaningfulAlpha(_ image: RasterImage) -> Bool {
        var i = 3
        while i < image.rgba.count {
            if image.rgba[i] < 255 { return true }
            i += 4
        }
        return false
    }

    // MARK: - Working resolution

    struct WorkSize: Equatable { var w: Int; var h: Int }

    static func workingSize(width: Int, height: Int, maxSide: Int) -> WorkSize {
        let longest = max(width, height)
        guard longest > maxSide else { return WorkSize(w: width, h: height) }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        return WorkSize(w: w, h: h)
    }

    /// Nearest-neighbour resample of the RGB planes into `toWidth × toHeight`
    /// tuples in 0…1. Alpha is ignored (the input is treated as opaque).
    static func sampleRGB(_ image: RasterImage, toWidth: Int, toHeight: Int) -> [(r: Double, g: Double, b: Double)] {
        var out = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: toWidth * toHeight)
        for gy in 0..<toHeight {
            let sy = min(image.height - 1, gy * image.height / toHeight)
            for gx in 0..<toWidth {
                let sx = min(image.width - 1, gx * image.width / toWidth)
                let base = (sy * image.width + sx) * 4
                out[gy * toWidth + gx] = (
                    Double(image.rgba[base]) / 255,
                    Double(image.rgba[base + 1]) / 255,
                    Double(image.rgba[base + 2]) / 255)
            }
        }
        return out
    }

    // MARK: - Background plane model

    /// A per-channel affine model of the background: `c ≈ ax·nx + ay·ny + b`,
    /// with the residual statistics of the border samples that fit it.
    struct BackgroundModel {
        var coeff: [(ax: Double, ay: Double, b: Double)]   // one per channel
        var residualMean: Double
        var residualStd: Double
    }

    /// Collect the border-ring pixel indices (the background prior).
    static func borderIndices(width: Int, height: Int, inset: Int) -> [Int] {
        var idx: [Int] = []
        for y in 0..<height {
            for x in 0..<width where x < inset || x >= width - inset || y < inset || y >= height - inset {
                idx.append(y * width + x)
            }
        }
        return idx
    }

    static func fitBackgroundPlane(rgb: [(r: Double, g: Double, b: Double)],
                                   width: Int, height: Int, inset: Int) -> BackgroundModel {
        let border = borderIndices(width: width, height: height, inset: inset)
        func norm(_ i: Int) -> (nx: Double, ny: Double) {
            let x = i % width, y = i / width
            return ((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
        }
        func channel(_ i: Int, _ c: Int) -> Double {
            let p = rgb[i]
            return c == 0 ? p.r : (c == 1 ? p.g : p.b)
        }

        var coeff = [(ax: Double, ay: Double, b: Double)](repeating: (0, 0, 0), count: 3)
        // Fit each channel by least squares over [nx, ny, 1]. Fall back to the
        // border mean when the system is singular (a 1-pixel-wide image, or a
        // degenerate ring with no positional spread).
        for c in 0..<3 {
            if let solved = solvePlane(border.map { (norm($0), channel($0, c)) }) {
                coeff[c] = solved
            } else {
                let mean = border.reduce(0.0) { $0 + channel($1, c) } / Double(border.count)
                coeff[c] = (0, 0, mean)
            }
        }

        // Residual statistics of the border against the fitted model — the
        // adaptive noise floor for classification.
        var residuals: [Double] = []
        residuals.reserveCapacity(border.count)
        for i in border {
            let (nx, ny) = norm(i)
            let dr = channel(i, 0) - (coeff[0].ax * nx + coeff[0].ay * ny + coeff[0].b)
            let dg = channel(i, 1) - (coeff[1].ax * nx + coeff[1].ay * ny + coeff[1].b)
            let db = channel(i, 2) - (coeff[2].ax * nx + coeff[2].ay * ny + coeff[2].b)
            residuals.append((dr * dr + dg * dg + db * db).squareRoot())
        }
        let mean = residuals.reduce(0, +) / Double(residuals.count)
        let variance = residuals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(residuals.count)
        return BackgroundModel(coeff: coeff, residualMean: mean, residualStd: variance.squareRoot())
    }

    /// Solve the 3-parameter least-squares plane `v ≈ ax·nx + ay·ny + b` via the
    /// normal equations (Cramer's rule on the symmetric 3×3 system). Returns nil
    /// when the system is singular (insufficient positional spread).
    static func solvePlane(_ samples: [((nx: Double, ny: Double), Double)]) -> (ax: Double, ay: Double, b: Double)? {
        var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0, s1 = 0.0
        var bx = 0.0, by = 0.0, b1 = 0.0
        for (pos, v) in samples {
            let x = pos.nx, y = pos.ny
            sxx += x * x; sxy += x * y; sx += x
            syy += y * y; sy += y; s1 += 1
            bx += x * v; by += y * v; b1 += v
        }
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, s1]]
        let det = determinant3(m)
        guard abs(det) > 1e-9 else { return nil }
        let ax = determinant3(replaceColumn(m, 0, [bx, by, b1])) / det
        let ay = determinant3(replaceColumn(m, 1, [bx, by, b1])) / det
        let b = determinant3(replaceColumn(m, 2, [bx, by, b1])) / det
        return (ax, ay, b)
    }

    static func determinant3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    static func replaceColumn(_ m: [[Double]], _ col: Int, _ v: [Double]) -> [[Double]] {
        var out = m
        for r in 0..<3 { out[r][col] = v[r] }
        return out
    }

    // MARK: - Classification

    static func classify(rgb: [(r: Double, g: Double, b: Double)], width: Int, height: Int,
                         model: BackgroundModel, baseThreshold: Double, noiseSigma: Double) -> [Bool] {
        let threshold = max(baseThreshold, model.residualMean + noiseSigma * model.residualStd)
        var fg = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let ny = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let nx = (Double(x) + 0.5) / Double(width)
                let i = y * width + x
                let p = rgb[i]
                let dr = p.r - (model.coeff[0].ax * nx + model.coeff[0].ay * ny + model.coeff[0].b)
                let dg = p.g - (model.coeff[1].ax * nx + model.coeff[1].ay * ny + model.coeff[1].b)
                let db = p.b - (model.coeff[2].ax * nx + model.coeff[2].ay * ny + model.coeff[2].b)
                fg[i] = (dr * dr + dg * dg + db * db).squareRoot() > threshold
            }
        }
        return fg
    }

    // MARK: - Morphology (3×3 structuring element)

    static func erode(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        morph(src, width: width, height: height, foregroundWins: false)
    }

    static func dilate(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        morph(src, width: width, height: height, foregroundWins: true)
    }

    /// One 3×3 morphological pass. `foregroundWins == true` → dilation (a cell
    /// is set if any neighbour is set); `false` → erosion (a cell stays set only
    /// if every neighbour is set). Out-of-bounds neighbours count as background.
    static func morph(_ src: [Bool], width: Int, height: Int, foregroundWins: Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var anySet = false, allSet = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        let inside = nx >= 0 && nx < width && ny >= 0 && ny < height
                        if inside && src[ny * width + nx] { anySet = true } else { allSet = false }
                    }
                }
                out[y * width + x] = foregroundWins ? anySet : allSet
            }
        }
        return out
    }

    /// Opening (erode → dilate): removes speck noise smaller than the element.
    static func open(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        dilate(erode(src, width: width, height: height), width: width, height: height)
    }

    /// Closing (dilate → erode): fills pinholes smaller than the element while
    /// leaving genuine interior holes (background-coloured regions) alone.
    static func close(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        erode(dilate(src, width: width, height: height), width: width, height: height)
    }

    // MARK: - Connected components

    /// Keep only the largest 4-connected foreground component (drops islands).
    static func largestComponent(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        var label = [Int](repeating: 0, count: width * height)   // 0 = unlabelled
        var sizes: [Int] = [0]                                   // indexed by label
        var next = 1
        var stack: [Int] = []
        for start in 0..<src.count where src[start] && label[start] == 0 {
            label[start] = next
            var size = 0
            stack.append(start)
            while let cur = stack.popLast() {
                size += 1
                let cx = cur % width, cy = cur / width
                let neighbours = [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                for (nx, ny) in neighbours where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let ni = ny * width + nx
                    if src[ni] && label[ni] == 0 {
                        label[ni] = next
                        stack.append(ni)
                    }
                }
            }
            sizes.append(size)
            next += 1
        }
        guard sizes.count > 1 else { return src }   // nothing foreground
        var best = 1
        for l in 1..<sizes.count where sizes[l] > sizes[best] { best = l }
        return label.map { $0 == best }
    }

    // MARK: - Upsample

    /// Nearest-neighbour upsample of a working-resolution foreground mask into a
    /// native-resolution alpha buffer (0 / 255).
    static func upsampleAlpha(_ fg: [Bool], fromWidth: Int, fromHeight: Int,
                              toWidth: Int, toHeight: Int) -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: toWidth * toHeight)
        for y in 0..<toHeight {
            let sy = min(fromHeight - 1, y * fromHeight / toHeight)
            for x in 0..<toWidth {
                let sx = min(fromWidth - 1, x * fromWidth / toWidth)
                alpha[y * toWidth + x] = fg[sy * fromWidth + sx] ? 255 : 0
            }
        }
        return alpha
    }
}
