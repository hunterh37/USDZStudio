import Foundation

/// Per-axis interpolation kernels for the lattice (FFD) deformer
/// (specs/mesh-editing.md §Lattice deformer). Free-form deformation evaluates a
/// **trivariate tensor product** of 1D bases, so all the interpolation math
/// lives here as a single-axis sampler and `LatticeCage` composes three of them.
///
/// A sample answers: for a normalized coordinate `c` (∈ `[0, 1]` inside the
/// cage; outside values are permitted and *extrapolate*), which run of control
/// nodes along one axis contributes, and with what weights. Weights always form
/// a partition of unity (∑ = 1) so a cage at rest reproduces its input, and both
/// bases have *linear precision* (reproduce an affine node field exactly) — the
/// property the rest-identity and affine-reproduction invariants lean on.
enum FFDBasis {

    /// A contiguous run of control-node indices along one axis and the weight
    /// each contributes. `firstIndex` may be negative (cubic reaches one node
    /// before the start); the caller's control-point accessor extrapolates
    /// out-of-range indices linearly, which keeps linear precision at the borders.
    struct AxisSample {
        let firstIndex: Int
        let weights: [Double]
    }

    /// Sample one axis.
    ///
    /// - `coord`: normalized coordinate (node-space is `coord · (count − 1)`).
    /// - `count`: number of control nodes on this axis (≥ 2, enforced upstream).
    static func sample(_ coord: Double, count: Int, interpolation: LatticeCage.Interpolation) -> AxisSample {
        switch interpolation {
        case .trilinear: return linear(coord, count: count)
        case .cubicBSpline: return cubic(coord, count: count)
        }
    }

    /// Degree-1 (piecewise-linear) sampling — "Linear Sharp": C⁰, cheap, visible
    /// creases between cells at resolution > 2. The enclosing cell is `[base,
    /// base+1]`; `t` is the fractional position within it and extrapolates past
    /// `[0, 1]` when `coord` is outside the cage.
    static func linear(_ coord: Double, count: Int) -> AxisSample {
        let fs = coord * Double(count - 1)
        // Clamp the cell so both nodes are in range; extrapolation is carried by
        // `t` (which may fall outside `[0, 1]`), never by an out-of-range index.
        let base = min(max(Int(floor(fs)), 0), count - 2)
        let t = fs - Double(base)
        return AxisSample(firstIndex: base, weights: [1 - t, t])
    }

    /// Uniform cubic B-spline sampling — "Cubic": C², smooth across cells. Uses
    /// the four nodes `[base-1 … base+2]`; the two boundary reaches (`base-1` at
    /// the start, `base+2` at the end) resolve through the caller's linear
    /// extrapolation, which is what preserves affine reproduction at the borders.
    static func cubic(_ coord: Double, count: Int) -> AxisSample {
        let fs = coord * Double(count - 1)
        let base = min(max(Int(floor(fs)), 0), count - 2)
        let t = fs - Double(base)
        let t2 = t * t, t3 = t2 * t
        // Standard uniform cubic B-spline basis over the window [base-1 … base+2].
        let w0 = (1 - 3 * t + 3 * t2 - t3) / 6      // (1-t)³ / 6
        let w1 = (4 - 6 * t2 + 3 * t3) / 6
        let w2 = (1 + 3 * t + 3 * t2 - 3 * t3) / 6
        let w3 = t3 / 6
        return AxisSample(firstIndex: base - 1, weights: [w0, w1, w2, w3])
    }
}
