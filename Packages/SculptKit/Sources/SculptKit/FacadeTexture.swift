import Foundation

/// A parametric window-grid facade texture (#147).
///
/// Architectural sculpts are capped at a five-primitive vocabulary with flat
/// PBR colours, so a building box reads as a stylised diorama rather than a
/// recreation. Rather than pay for that detail in geometry, a `FacadeTexture`
/// describes a repeating window grid that the surface pass bakes into albedo +
/// emissive maps for near-zero geometry cost: rows/columns of windows, a lit
/// fraction (emissive night-time glow), and deterministic per-window jitter so
/// the lit pattern looks organic instead of checkerboard-regular.
///
/// The spec is pure data; `FacadeTextureGenerator` turns it into `RasterImage`
/// pixel buffers (RGBA8) and the AgentMCP/EditorUI runner writes those to PNG
/// and binds them — keeping SculptKit pixel-codec-free.
public struct FacadeTexture: Codable, Sendable, Equatable {
    /// Number of window rows.
    public var rows: Int
    /// Number of window columns.
    public var columns: Int
    /// Fraction of windows that are lit/emissive, 0...1.
    public var litFraction: Double
    /// Linear RGB (0...1) of the wall/facade between windows.
    public var wallColor: [Double]
    /// Linear RGB (0...1) of an unlit window (glass).
    public var windowColor: [Double]
    /// Linear RGB (0...1) emissive colour of a lit window.
    public var litColor: [Double]
    /// Seed for the deterministic lit-window pattern + colour jitter.
    public var seed: UInt64
    /// Square output resolution in pixels (clamped to a sane range).
    public var resolution: Int

    public init(rows: Int, columns: Int, litFraction: Double = 0.35,
                wallColor: [Double] = [0.10, 0.10, 0.12],
                windowColor: [Double] = [0.02, 0.03, 0.05],
                litColor: [Double] = [1.0, 0.85, 0.55],
                seed: UInt64 = 0, resolution: Int = 256) {
        self.rows = rows
        self.columns = columns
        self.litFraction = litFraction
        self.wallColor = wallColor
        self.windowColor = windowColor
        self.litColor = litColor
        self.seed = seed
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case rows, columns, litFraction, wallColor, windowColor, litColor, seed, resolution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decode(Int.self, forKey: .rows)
        columns = try c.decode(Int.self, forKey: .columns)
        litFraction = try c.decodeIfPresent(Double.self, forKey: .litFraction) ?? 0.35
        wallColor = try c.decodeIfPresent([Double].self, forKey: .wallColor) ?? [0.10, 0.10, 0.12]
        windowColor = try c.decodeIfPresent([Double].self, forKey: .windowColor) ?? [0.02, 0.03, 0.05]
        litColor = try c.decodeIfPresent([Double].self, forKey: .litColor) ?? [1.0, 0.85, 0.55]
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? 256
    }
}

/// The pair of maps a facade bakes into: base colour + emissive.
public struct FacadeMaps: Sendable, Equatable {
    public let albedo: RasterImage
    public let emissive: RasterImage
}

/// Bakes a `FacadeTexture` spec into deterministic RGBA8 pixel buffers.
///
/// Fully self-contained (no pixel codecs, no randomness beyond the seeded
/// splitmix64 stream) so it is unit-testable to the line and reproducible for
/// the render/eval gates.
public enum FacadeTextureGenerator {

    /// Validated bounds for spec fields. Generation clamps to these so a
    /// malformed spec still produces a usable (if degenerate) texture rather
    /// than trapping.
    public static let resolutionRange = 16...2048
    public static let maxWindowsPerAxis = 256

    public static func generate(_ spec: FacadeTexture) -> FacadeMaps {
        let side = min(max(spec.resolution, resolutionRange.lowerBound), resolutionRange.upperBound)
        let cols = min(max(spec.columns, 1), maxWindowsPerAxis)
        let rows = min(max(spec.rows, 1), maxWindowsPerAxis)
        let lit = min(max(spec.litFraction, 0), 1)

        let wall = clampRGB(spec.wallColor)
        let glass = clampRGB(spec.windowColor)
        let litRGB = clampRGB(spec.litColor)

        var albedo = [UInt8](repeating: 0, count: side * side * 4)
        var emissive = [UInt8](repeating: 0, count: side * side * 4)

        // Fill wall background (opaque). Emissive starts black.
        let wallBytes = rgba8(wall)
        for p in 0..<(side * side) {
            let b = p * 4
            albedo[b] = wallBytes.0; albedo[b + 1] = wallBytes.1
            albedo[b + 2] = wallBytes.2; albedo[b + 3] = 255
            emissive[b + 3] = 255
        }

        // Cell geometry: each window sits inside a cell with a mullion gap so
        // adjacent windows never touch. The window occupies the central 70% of
        // the cell in each axis.
        let cellW = Double(side) / Double(cols)
        let cellH = Double(side) / Double(rows)
        let windowFill = 0.70

        for r in 0..<rows {
            for c in 0..<cols {
                // Deterministic per-window value drives lit decision + jitter.
                var rng = SplitMix64(seed: spec.seed &+ UInt64(r) &* 0x9E3779B97F4A7C15 &+ UInt64(c))
                let roll = rng.nextUnitDouble()
                let isLit = roll < lit
                // Brightness jitter so lit windows aren't uniform.
                let jitter = 0.75 + 0.25 * rng.nextUnitDouble()

                let x0 = Int((Double(c) + (1 - windowFill) / 2) * cellW)
                let x1 = Int((Double(c) + 1 - (1 - windowFill) / 2) * cellW)
                let y0 = Int((Double(r) + (1 - windowFill) / 2) * cellH)
                let y1 = Int((Double(r) + 1 - (1 - windowFill) / 2) * cellH)
                guard x1 > x0, y1 > y0 else { continue }

                let glassBytes = rgba8(glass)
                let litBytes = rgba8(litRGB.map { min(1, $0 * jitter) })

                for y in y0..<min(y1, side) {
                    for x in x0..<min(x1, side) {
                        let b = (y * side + x) * 4
                        albedo[b] = glassBytes.0; albedo[b + 1] = glassBytes.1; albedo[b + 2] = glassBytes.2
                        if isLit {
                            emissive[b] = litBytes.0; emissive[b + 1] = litBytes.1; emissive[b + 2] = litBytes.2
                            // Lit windows read brighter in albedo too.
                            albedo[b] = litBytes.0; albedo[b + 1] = litBytes.1; albedo[b + 2] = litBytes.2
                        }
                    }
                }
            }
        }

        // Buffers are allocated at exactly `side*side*4`, so RasterImage's only
        // failure mode (size mismatch) is unreachable — the force-unwraps are
        // provably safe.
        let a = RasterImage(width: side, height: side, rgba: albedo)!
        let e = RasterImage(width: side, height: side, rgba: emissive)!
        return FacadeMaps(albedo: a, emissive: e)
    }

    private static func clampRGB(_ rgb: [Double]) -> [Double] {
        let c = rgb.count >= 3 ? rgb : rgb + Array(repeating: 0, count: 3 - rgb.count)
        return c.prefix(3).map { min(max($0, 0), 1) }
    }

    private static func rgba8(_ rgb: [Double]) -> (UInt8, UInt8, UInt8) {
        func b(_ v: Double) -> UInt8 { UInt8(min(255, max(0, (v * 255).rounded()))) }
        return (b(rgb[0]), b(rgb[1]), b(rgb[2]))
    }
}

/// Minimal deterministic PRNG (splitmix64) — no Foundation randomness so the
/// baked texture is byte-identical across platforms and runs.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform double in [0, 1).
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
