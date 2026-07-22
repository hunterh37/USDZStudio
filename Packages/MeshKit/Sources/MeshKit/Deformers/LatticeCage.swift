import Foundation

/// Cached lattice binding: each mesh vertex's normalized `(s, t, u)` coordinate
/// in a cage's rest frame, alongside the rest position it was bound from.
///
/// Binding is computed once against the *rest* cage (`LatticeCage.bind`); editing
/// then only moves control points and `deform` re-evaluates the tensor product
/// against these fixed coordinates — O(vertices) per edit. Carrying `restPoints`
/// makes `deform` self-contained: vertices outside the cage (when
/// `affectOutside == false`) pass straight through to their rest position with no
/// second array to thread.
public struct LatticeBinding: Sendable, Equatable {
    /// Normalized cage coordinates, parallel to the bound point array. `(s,t,u)`
    /// ∈ `[0,1]³` for points inside the cage; outside values are kept verbatim.
    public let localCoords: [SIMD3<Double>]
    /// The rest positions this binding was computed from, parallel to `localCoords`.
    public let restPoints: [SIMD3<Double>]

    public init(localCoords: [SIMD3<Double>], restPoints: [SIMD3<Double>]) {
        self.localCoords = localCoords
        self.restPoints = restPoints
    }
}

/// Free-form deformation lattice cage (Sederberg & Parry, SIGGRAPH 1986;
/// research/topics/lattice-deformer). An oriented `l×m×n` grid of control points
/// wraps a mesh; each vertex is expressed in the cage's local `(s,t,u)` frame and
/// re-evaluated as a trivariate tensor product of the displaced control points,
/// producing a smooth deformation of the enclosed geometry.
///
/// Pure value type in MeshKit's idiom: `Double` math, no `simd`/UI/GPU imports.
/// The deform is the deterministic source of truth; any GPU preview kernel is a
/// parity-tested accelerator layered above it, never a substitute.
public struct LatticeCage: Sendable, Equatable {

    /// Per-axis interpolation basis. `trilinear` is C⁰ and cheap ("Linear
    /// Sharp"); `cubicBSpline` is C² and smooth across cells ("Cubic").
    public enum Interpolation: Sendable, Equatable, CaseIterable {
        case trilinear
        case cubicBSpline
    }

    /// Control-point count per axis. Each ≥ 2 (a single-node axis has no cell)
    /// and ≤ `maxPerAxis`.
    public struct Resolution: Sendable, Equatable {
        public var l: Int
        public var m: Int
        public var n: Int
        public init(l: Int, m: Int, n: Int) { self.l = l; self.m = m; self.n = n }

        /// Blender-parity default: corners only — a `2×2×2` cage is an affine
        /// handle box.
        public static let `default` = Resolution(l: 2, m: 2, n: 2)
        public var pointCount: Int { l * m * n }
    }

    /// Upper bound per axis (Blender-parity ceiling; keeps handle counts sane).
    public static let maxPerAxis = 8

    /// Rest frame origin (the `(0,0,0)` local corner).
    public var origin: SIMD3<Double>
    /// Spanning vectors: local `(s,t,u)` maps to `origin + s·edgeS + t·edgeT + u·edgeU`.
    /// Need not be axis-aligned or orthogonal (an oriented parallelepiped).
    public var edgeS: SIMD3<Double>
    public var edgeT: SIMD3<Double>
    public var edgeU: SIMD3<Double>
    public var resolution: Resolution
    public var interpolation: Interpolation
    /// When `false`, geometry outside the cage (`(s,t,u)` beyond `[0,1]`) is left
    /// in place; when `true`, the basis extrapolates and deforms it too.
    public var affectOutside: Bool
    /// Row-major control-point grid: `controlPoints[i + l·(j + m·k)]`, count == `resolution.pointCount`.
    public var controlPoints: [SIMD3<Double>]

    /// Regular cage: control points fill the rest frame on a uniform grid.
    public init(origin: SIMD3<Double>,
                edgeS: SIMD3<Double>,
                edgeT: SIMD3<Double>,
                edgeU: SIMD3<Double>,
                resolution: Resolution = .default,
                interpolation: Interpolation = .trilinear,
                affectOutside: Bool = false) {
        self.origin = origin
        self.edgeS = edgeS
        self.edgeT = edgeT
        self.edgeU = edgeU
        self.resolution = resolution
        self.interpolation = interpolation
        self.affectOutside = affectOutside
        self.controlPoints = Self.restGrid(origin: origin, edgeS: edgeS, edgeT: edgeT,
                                            edgeU: edgeU, resolution: resolution)
    }

    /// Cage with explicit (already-displaced) control points — used when
    /// decoding an in-progress edit. Count must equal `resolution.pointCount`.
    public init(origin: SIMD3<Double>,
                edgeS: SIMD3<Double>,
                edgeT: SIMD3<Double>,
                edgeU: SIMD3<Double>,
                resolution: Resolution,
                interpolation: Interpolation,
                affectOutside: Bool,
                controlPoints: [SIMD3<Double>]) {
        self.origin = origin
        self.edgeS = edgeS
        self.edgeT = edgeT
        self.edgeU = edgeU
        self.resolution = resolution
        self.interpolation = interpolation
        self.affectOutside = affectOutside
        self.controlPoints = controlPoints
    }

    /// Axis-aligned cage fitted to a min/max bounding box (the common entry
    /// point: fit the cage to the selected mesh's bounds).
    public static func fitted(min lo: SIMD3<Double>,
                              max hi: SIMD3<Double>,
                              resolution: Resolution = .default,
                              interpolation: Interpolation = .trilinear,
                              affectOutside: Bool = false) -> LatticeCage {
        LatticeCage(origin: lo,
                    edgeS: SIMD3(hi.x - lo.x, 0, 0),
                    edgeT: SIMD3(0, hi.y - lo.y, 0),
                    edgeU: SIMD3(0, 0, hi.z - lo.z),
                    resolution: resolution,
                    interpolation: interpolation,
                    affectOutside: affectOutside)
    }

    /// Rest control-point grid for a frame + resolution (uniform spacing).
    public static func restGrid(origin: SIMD3<Double>,
                                edgeS: SIMD3<Double>,
                                edgeT: SIMD3<Double>,
                                edgeU: SIMD3<Double>,
                                resolution r: Resolution) -> [SIMD3<Double>] {
        var pts: [SIMD3<Double>] = []
        pts.reserveCapacity(r.pointCount)
        // Guard the (count-1) denominators; validation rejects r < 2 before a
        // deform, but restGrid is also called from `init` so stay total here.
        let ds = r.l > 1 ? 1.0 / Double(r.l - 1) : 0
        let dt = r.m > 1 ? 1.0 / Double(r.m - 1) : 0
        let du = r.n > 1 ? 1.0 / Double(r.n - 1) : 0
        for k in 0..<r.n {
            for j in 0..<r.m {
                for i in 0..<r.l {
                    pts.append(origin
                               + Double(i) * ds * edgeS
                               + Double(j) * dt * edgeT
                               + Double(k) * du * edgeU)
                }
            }
        }
        return pts
    }

    // MARK: Validation

    /// Reject cages that cannot deform: degenerate resolution, wrong control
    /// count, or a flat (zero-volume) rest frame whose local-coordinate solve
    /// would divide by ~0.
    public func validate() throws {
        let r = resolution
        guard r.l >= 2, r.m >= 2, r.n >= 2 else {
            throw MeshOpError.preconditionFailed("lattice resolution must be ≥ 2 on every axis")
        }
        guard r.l <= Self.maxPerAxis, r.m <= Self.maxPerAxis, r.n <= Self.maxPerAxis else {
            throw MeshOpError.preconditionFailed("lattice resolution must be ≤ \(Self.maxPerAxis) on every axis")
        }
        guard controlPoints.count == r.pointCount else {
            throw MeshOpError.preconditionFailed(
                "lattice has \(controlPoints.count) control points, expected \(r.pointCount)")
        }
        guard abs(frameDeterminant) > MeshInvariants.epsilon else {
            throw MeshOpError.preconditionFailed("lattice rest frame is degenerate (zero volume)")
        }
    }

    /// Scalar triple product `S · (T × U)` — the signed rest-frame volume; the
    /// shared denominator of the local-coordinate solve.
    var frameDeterminant: Double { simd_dot(edgeS, simd_cross(edgeT, edgeU)) }

    // MARK: Binding

    /// Normalized cage coordinate of a world point via the scalar-triple-product
    /// solve (numerically stable, no matrix inverse). Requires a non-degenerate
    /// frame — call `validate()` first.
    public func localCoordinate(of p: SIMD3<Double>) -> SIMD3<Double> {
        let rel = p - origin
        let s = simd_dot(simd_cross(edgeT, edgeU), rel) / simd_dot(simd_cross(edgeT, edgeU), edgeS)
        let t = simd_dot(simd_cross(edgeS, edgeU), rel) / simd_dot(simd_cross(edgeS, edgeU), edgeT)
        let u = simd_dot(simd_cross(edgeS, edgeT), rel) / simd_dot(simd_cross(edgeS, edgeT), edgeU)
        return SIMD3(s, t, u)
    }

    /// Bind a point array against this cage's rest frame. Throws if the cage is
    /// invalid (so callers never bind against a degenerate frame).
    public func bind(points: [SIMD3<Double>]) throws -> LatticeBinding {
        try validate()
        return LatticeBinding(localCoords: points.map(localCoordinate(of:)), restPoints: points)
    }

    // MARK: Deform

    /// Deform a bound point array with the current control points. Pure and
    /// deterministic; parallel to `binding.restPoints`.
    public func deform(_ binding: LatticeBinding) -> [SIMD3<Double>] {
        let r = resolution
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(binding.localCoords.count)
        for (idx, c) in binding.localCoords.enumerated() {
            if !affectOutside && isOutside(c) {
                out.append(binding.restPoints[idx])
                continue
            }
            let sx = FFDBasis.sample(c.x, count: r.l, interpolation: interpolation)
            let sy = FFDBasis.sample(c.y, count: r.m, interpolation: interpolation)
            let sz = FFDBasis.sample(c.z, count: r.n, interpolation: interpolation)
            var acc = SIMD3<Double>.zero
            for kk in sz.weights.indices {
                let wk = sz.weights[kk]
                for jj in sy.weights.indices {
                    let wjk = wk * sy.weights[jj]
                    for ii in sx.weights.indices {
                        let w = wjk * sx.weights[ii]
                        acc += w * controlPoint(sx.firstIndex + ii,
                                                sy.firstIndex + jj,
                                                sz.firstIndex + kk)
                    }
                }
            }
            out.append(acc)
        }
        return out
    }

    private func isOutside(_ c: SIMD3<Double>) -> Bool {
        c.x < 0 || c.x > 1 || c.y < 0 || c.y > 1 || c.z < 0 || c.z > 1
    }

    /// Control point at a grid index, with **linear extrapolation** for
    /// out-of-range indices (per axis). Separable linear extrapolation reproduces
    /// an affine control field exactly, so cubic sampling keeps linear precision
    /// at the cage borders and the rest cage reproduces its input everywhere.
    func controlPoint(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
        let r = resolution
        if i < 0 { return 2 * controlPoint(0, j, k) - controlPoint(1, j, k) }
        if i > r.l - 1 { return 2 * controlPoint(r.l - 1, j, k) - controlPoint(r.l - 2, j, k) }
        if j < 0 { return 2 * controlPoint(i, 0, k) - controlPoint(i, 1, k) }
        if j > r.m - 1 { return 2 * controlPoint(i, r.m - 1, k) - controlPoint(i, r.m - 2, k) }
        if k < 0 { return 2 * controlPoint(i, j, 0) - controlPoint(i, j, 1) }
        if k > r.n - 1 { return 2 * controlPoint(i, j, r.n - 1) - controlPoint(i, j, r.n - 2) }
        return controlPoints[i + r.l * (j + r.m * k)]
    }
}
