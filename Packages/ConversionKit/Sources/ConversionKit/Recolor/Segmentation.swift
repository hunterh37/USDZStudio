import Foundation

/// Auto-segmentation for multi-color textures (specs/recoloring.md §Masks):
/// cluster the albedo in OKLab so "fabric" separates from "printed logo", and
/// seed a mask from a viewport click's UV + a similarity threshold. Pure and
/// deterministic — clustering uses a fixed seeding rule, no RNG.
public struct RecolorSegmenter: Sendable {
    public init() {}

    /// k-means over the image's OKLab samples. Returns a per-pixel cluster
    /// label (row-major, values in 0..<k) plus each cluster's OKLab center.
    /// Centers are seeded deterministically (evenly strided pixels) so results
    /// are reproducible across runs and machines.
    public func cluster(
        _ image: RGBAImage,
        colorSpace: TextureColorSpace,
        clusters k: Int,
        iterations: Int = 8
    ) -> (labels: [Int], centers: [OKLab]) {
        precondition(k >= 1, "cluster count must be >= 1")
        precondition(iterations >= 1, "iterations must be >= 1")
        let samples = oklabSamples(image, colorSpace: colorSpace)
        // Deterministic seeding: pick k evenly-strided pixels as initial centers.
        var centers: [OKLab] = []
        let stride = max(1, samples.count / k)
        for i in 0..<k {
            centers.append(samples[min(i * stride, samples.count - 1)])
        }
        var labels = [Int](repeating: 0, count: samples.count)
        for _ in 0..<iterations {
            // Assignment step.
            for (index, sample) in samples.enumerated() {
                labels[index] = nearestCenter(to: sample, centers: centers)
            }
            // Update step.
            var sums = [OKLab](repeating: OKLab(L: 0, a: 0, b: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (index, sample) in samples.enumerated() {
                let c = labels[index]
                sums[c].L += sample.L
                sums[c].a += sample.a
                sums[c].b += sample.b
                counts[c] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                let n = Double(counts[c])
                centers[c] = OKLab(L: sums[c].L / n, a: sums[c].a / n, b: sums[c].b / n)
            }
        }
        return (labels, centers)
    }

    /// A binary mask selecting the cluster that owns the pixel under `uv`
    /// (u,v in [0,1], v measured top-down to match texture rows). Used when a
    /// user clicks a 3D part and the hit UV seeds the region.
    public func clusterMask(
        _ image: RGBAImage,
        colorSpace: TextureColorSpace,
        clusters k: Int,
        atUV uv: (u: Double, v: Double),
        iterations: Int = 8
    ) -> RecolorMask {
        let result = cluster(image, colorSpace: colorSpace, clusters: k, iterations: iterations)
        let seed = pixelIndex(forUV: uv, width: image.width, height: image.height)
        let target = result.labels[seed]
        let coverage = result.labels.map { $0 == target ? 1.0 : 0.0 }
        return RecolorMask(width: image.width, height: image.height, coverage: coverage)
    }

    /// A similarity mask: every pixel within `threshold` OKLab distance of the
    /// sample under `uv` is selected. `feather` softens the boundary — pixels
    /// between `threshold` and `threshold + feather` ramp from 1 to 0.
    public func similarityMask(
        _ image: RGBAImage,
        colorSpace: TextureColorSpace,
        atUV uv: (u: Double, v: Double),
        threshold: Double,
        feather: Double = 0
    ) -> RecolorMask {
        precondition(threshold >= 0, "threshold must be non-negative")
        precondition(feather >= 0, "feather must be non-negative")
        let samples = oklabSamples(image, colorSpace: colorSpace)
        let seed = samples[pixelIndex(forUV: uv, width: image.width, height: image.height)]
        let coverage = samples.map { sample -> Double in
            let d = distance(sample, seed)
            if d <= threshold { return 1 }
            if feather > 0, d < threshold + feather { return 1 - (d - threshold) / feather }
            return 0
        }
        return RecolorMask(width: image.width, height: image.height, coverage: coverage)
    }

    // MARK: - Helpers

    private func oklabSamples(_ image: RGBAImage, colorSpace: TextureColorSpace) -> [OKLab] {
        var samples = [OKLab]()
        samples.reserveCapacity(image.pixelCount)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = image.pixel(x: x, y: y)
                let linear = ColorManagement.decode(
                    (Double(p.r) / 255.0, Double(p.g) / 255.0, Double(p.b) / 255.0),
                    from: colorSpace
                )
                samples.append(OKLab(linear: linear))
            }
        }
        return samples
    }

    private func nearestCenter(to sample: OKLab, centers: [OKLab]) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let d = distance(sample, center)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }

    private func distance(_ a: OKLab, _ b: OKLab) -> Double {
        let dL = a.L - b.L
        let da = a.a - b.a
        let db = a.b - b.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// Map a UV coordinate to a clamped row-major pixel index.
    func pixelIndex(forUV uv: (u: Double, v: Double), width: Int, height: Int) -> Int {
        let clampedU = min(max(uv.u, 0), 1)
        let clampedV = min(max(uv.v, 0), 1)
        let x = min(width - 1, Int(clampedU * Double(width)))
        let y = min(height - 1, Int(clampedV * Double(height)))
        return y * width + x
    }
}
