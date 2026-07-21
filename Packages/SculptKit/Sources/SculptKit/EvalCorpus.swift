import Foundation

// Sculpt-accuracy P0 (#81): the synthetic labelled benchmark.
//
// Each entry is a silhouette we author ourselves, so its foreground mask and
// camera pose are exact ground truth — no hand labelling, no fabricated data.
// Rendering the same shape as a clean matte and as a "raw photo" over a
// textured background reproduces the F1 finding (segmentation quality dominates)
// with a real, reproducible number instead of a one-off screenshot.

/// A procedurally-defined silhouette: a foreground predicate over normalized
/// image coordinates (both axes in 0...1, y downward) plus its ground-truth
/// camera pose.
public struct SilhouetteSpec: Sendable {
    public var name: String
    public var pose: ViewPose
    /// Foreground test at a normalized pixel centre.
    public var isForeground: @Sendable (_ nx: Double, _ ny: Double) -> Bool

    public init(name: String, pose: ViewPose,
                isForeground: @escaping @Sendable (Double, Double) -> Bool) {
        self.name = name
        self.pose = pose
        self.isForeground = isForeground
    }
}

public enum EvalCorpus {

    /// Foreground / background colours used by the renderer (linear 0...1).
    static let foregroundColor = (r: 0.20, g: 0.60, b: 0.25)
    static let backgroundBase = (r: 0.50, g: 0.50, b: 0.55)

    /// The frozen benchmark: 12 varied silhouettes (convex, concave, holed).
    /// N ≥ 10 per the P0 acceptance criterion.
    public static func specs() -> [SilhouetteSpec] {
        var out: [SilhouetteSpec] = []
        func add(_ name: String, az: Double, el: Double,
                 _ test: @escaping @Sendable (Double, Double) -> Bool) {
            out.append(SilhouetteSpec(name: name,
                                      pose: ViewPose(azimuthDegrees: az, elevationDegrees: el),
                                      isForeground: test))
        }
        add("disc", az: 0, el: 0) { nx, ny in
            let x = nx - 0.5, y = ny - 0.5
            return x * x + y * y <= 0.16
        }
        add("box", az: 30, el: 10) { nx, ny in
            abs(nx - 0.5) <= 0.32 && abs(ny - 0.5) <= 0.32
        }
        add("tall", az: 45, el: 0) { nx, ny in
            abs(nx - 0.5) <= 0.18 && abs(ny - 0.5) <= 0.4
        }
        add("wide", az: 90, el: 15) { nx, ny in
            abs(nx - 0.5) <= 0.42 && abs(ny - 0.5) <= 0.16
        }
        add("triangle", az: 120, el: 5) { nx, ny in
            ny >= 0.2 && ny <= 0.8 && abs(nx - 0.5) <= 0.4 * (ny - 0.2) / 0.6
        }
        add("car", az: 200, el: 8) { nx, ny in carSilhouette(nx, ny) }
        add("ell", az: 150, el: 0) { nx, ny in
            let stem = abs(nx - 0.4) <= 0.18 && abs(ny - 0.5) <= 0.35
            let foot = abs(ny - 0.7) <= 0.13 && nx >= 0.22 && nx <= 0.75
            return stem || foot
        }
        add("ring", az: 0, el: 60) { nx, ny in
            let x = nx - 0.5, y = ny - 0.5
            let r2 = x * x + y * y
            return r2 <= 0.16 && r2 >= 0.04   // annulus: a genuine interior hole
        }
        add("cross", az: 270, el: 0) { nx, ny in
            let vert = abs(nx - 0.5) <= 0.12 && abs(ny - 0.5) <= 0.38
            let horiz = abs(ny - 0.5) <= 0.12 && abs(nx - 0.5) <= 0.38
            return vert || horiz
        }
        add("ellipse", az: 60, el: 20) { nx, ny in
            let x = nx - 0.5, y = ny - 0.5
            return (x * x) / 0.16 + (y * y) / 0.04 <= 1
        }
        add("diamond", az: 315, el: 0) { nx, ny in
            abs(nx - 0.5) + abs(ny - 0.5) <= 0.38
        }
        add("trapezoid", az: 210, el: 30) { nx, ny in
            ny >= 0.25 && ny <= 0.75 && abs(nx - 0.5) <= 0.15 + 0.25 * (0.75 - ny) / 0.5
        }
        return out
    }

    /// A concave car silhouette: a body slab + cabin, minus two wheel-gap
    /// notches cut from the underside. The interior gaps are what a faithful
    /// reference must preserve (the crux of the F2 metric defect).
    static func carSilhouette(_ nx: Double, _ ny: Double) -> Bool {
        let body = ny >= 0.42 && ny <= 0.66 && nx >= 0.14 && nx <= 0.86
        let cabin = ny >= 0.30 && ny < 0.42 && nx >= 0.34 && nx <= 0.66
        let inBody = body || cabin
        // Wheel gaps: semicircular notches removed from the bottom edge.
        let gap1 = distance(nx, ny, 0.30, 0.66) <= 0.09
        let gap2 = distance(nx, ny, 0.70, 0.66) <= 0.09
        return inBody && !(gap1 || gap2)
    }

    static func distance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = ax - bx, dy = ay - by
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Render one spec into a labelled reference at `side × side`.
    public static func render(_ spec: SilhouetteSpec, side: Int = ImageSimilarity.gridSide) -> LabelledReference {
        var trueForeground = [Bool](repeating: false, count: side * side)
        var matted = [UInt8](repeating: 0, count: side * side * 4)
        var raw = [UInt8](repeating: 0, count: side * side * 4)

        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

        for y in 0..<side {
            let ny = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let nx = (Double(x) + 0.5) / Double(side)
                let idx = y * side + x
                let base = idx * 4
                let fg = spec.isForeground(nx, ny)
                trueForeground[idx] = fg

                if fg {
                    matted[base] = byte(foregroundColor.r)
                    matted[base + 1] = byte(foregroundColor.g)
                    matted[base + 2] = byte(foregroundColor.b)
                    matted[base + 3] = 255
                    raw[base] = matted[base]
                    raw[base + 1] = matted[base + 1]
                    raw[base + 2] = matted[base + 2]
                    raw[base + 3] = 255
                } else {
                    // Matte: transparent background.
                    matted[base + 3] = 0
                    // Raw photo: opaque textured background that drifts across the
                    // frame, so a corner-sampled colour key leaks (F1).
                    let drift = 0.30 * (nx + ny) / 2
                    raw[base] = byte(backgroundBase.r + drift)
                    raw[base + 1] = byte(backgroundBase.g + drift)
                    raw[base + 2] = byte(backgroundBase.b + drift)
                    raw[base + 3] = 255
                }
            }
        }

        return LabelledReference(
            name: spec.name,
            pose: spec.pose,
            trueForeground: trueForeground,
            matted: RasterImage(width: side, height: side, rgba: matted)!,
            raw: RasterImage(width: side, height: side, rgba: raw)!)
    }

    /// The whole rendered benchmark.
    public static func benchmark(side: Int = ImageSimilarity.gridSide) -> [LabelledReference] {
        specs().map { render($0, side: side) }
    }
}
