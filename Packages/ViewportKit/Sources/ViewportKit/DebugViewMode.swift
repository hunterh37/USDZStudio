import Foundation
import simd

/// The viewport's debug shading modes (specs/viewport.md "Debug View Modes").
///
/// Pure value type: the mode set, its per-mode presentation metadata, and the
/// *spec* describing how each mode should be realised on the projection
/// entities. The RealityKit coordinator (`ViewportPane`, coverage-excluded GPU
/// glue) consumes `materialSpec` / procedural textures produced here — all the
/// decision + pixel-generation logic lives in this file so it is unit-testable
/// without a GPU.
public enum DebugViewMode: String, CaseIterable, Identifiable, Sendable {
    /// Default: the file's own materials, untouched.
    case shaded
    /// File materials kept, plus an additive wireframe overlay.
    case wireframe
    /// Surface normals encoded as colour (matcap-mapped approximation).
    case normals
    /// A UV checker map, for spotting stretched/seamed texture coordinates.
    case uvChecker
    /// A neutral clay matcap, isolating form from material/lighting.
    case matcap

    public var id: String { rawValue }

    /// SF Symbol for the toolbar segmented control.
    public var symbol: String {
        switch self {
        case .shaded: "cube.fill"
        case .wireframe: "grid"
        case .normals: "arrow.up.left.and.arrow.down.right"
        case .uvChecker: "checkerboard.rectangle"
        case .matcap: "circle.lefthalf.filled"
        }
    }

    /// Short human label.
    public var label: String {
        switch self {
        case .shaded: "Shaded"
        case .wireframe: "Wireframe"
        case .normals: "Normals"
        case .uvChecker: "UV Checker"
        case .matcap: "Matcap"
        }
    }

    /// Tooltip describing what the mode reveals.
    public var helpText: String {
        switch self {
        case .shaded: "Shaded — the file's own materials"
        case .wireframe: "Wireframe — edge overlay on shaded geometry"
        case .normals: "Normals — surface normal direction as colour"
        case .uvChecker: "UV Checker — reveals texture-coordinate stretching"
        case .matcap: "Matcap — neutral clay, isolates surface form"
        }
    }

    /// `true` when the mode leaves the file materials in place and draws an
    /// additive overlay instead of swapping materials (only wireframe).
    public var isOverlay: Bool { self == .wireframe }

    /// `true` when the mode replaces the projection entities' materials with a
    /// generated debug material.
    public var replacesMaterials: Bool { materialSpec != nil }

    /// The debug material to apply, or `nil` for modes that keep the file
    /// materials (`shaded`, `wireframe`). Pure spec the RealityKit layer
    /// realises into a `Material`.
    public var materialSpec: DebugMaterialSpec? {
        switch self {
        case .shaded, .wireframe: nil
        case .normals: .init(kind: .normals, unlit: true)
        case .uvChecker: .init(kind: .uvChecker, unlit: false)
        case .matcap: .init(kind: .matcap, unlit: true)
        }
    }
}

/// A resolved, GPU-agnostic description of a debug material. The coordinator
/// turns `kind` into the matching procedural texture (via `DebugTextureFactory`)
/// and builds an unlit or PBR material accordingly.
public struct DebugMaterialSpec: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case normals, uvChecker, matcap
    }

    public var kind: Kind
    /// Unlit materials show the debug texture directly, unaffected by scene
    /// lighting (normals/matcap already encode their own shading); the UV
    /// checker keeps lighting so form stays readable.
    public var unlit: Bool

    public init(kind: Kind, unlit: Bool) {
        self.kind = kind
        self.unlit = unlit
    }
}

/// An RGBA8 image produced procedurally for a debug material. Pure data so the
/// pattern maths is unit-testable; the coordinator uploads `rgba` to a
/// `TextureResource`.
public struct DebugTexture: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes/pixel, length `width * height * 4`.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// The RGBA bytes of the pixel at `(x, y)` (top-left origin).
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
}

/// Pure pixel-generation for the debug materials. Every function is
/// deterministic and GPU-free, so the pattern maths carries the module's
/// coverage while the RealityKit upload stays in the excluded glue.
public enum DebugTextureFactory {

    /// Builds the texture for a spec kind at the given square size.
    public static func texture(for kind: DebugMaterialSpec.Kind, size: Int) -> DebugTexture {
        switch kind {
        case .normals: normalMatcap(size: size)
        case .uvChecker: uvChecker(size: size)
        case .matcap: clayMatcap(size: size)
        }
    }

    // MARK: UV checker

    /// Standard two-tone UV checker: `squares` tiles across each axis, with a
    /// thin darker gridline so seams are visible even on flat colour.
    public static func uvChecker(size: Int, squares: Int = 8) -> DebugTexture {
        precondition(size > 0 && squares > 0, "size and squares must be positive")
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size)
                let v = (Float(y) + 0.5) / Float(size)
                let color = checkerColor(u: u, v: v, squares: squares)
                let i = (y * size + x) * 4
                rgba[i] = color.x; rgba[i + 1] = color.y; rgba[i + 2] = color.z; rgba[i + 3] = 255
            }
        }
        return DebugTexture(width: size, height: size, rgba: rgba)
    }

    /// `true` when `(u, v)` lands on the "light" tile of a `squares × squares`
    /// checker over the 0…1 range.
    public static func checkerIsLight(u: Float, v: Float, squares: Int) -> Bool {
        let cx = Int(floor(u * Float(squares)))
        let cy = Int(floor(v * Float(squares)))
        return (cx + cy) & 1 == 0
    }

    /// RGB (0…255) for a checker cell: light/dark tile with a subtle gridline.
    static func checkerColor(u: Float, v: Float, squares: Int) -> SIMD3<UInt8> {
        let cell = 1 / Float(squares)
        let fu = (u.truncatingRemainder(dividingBy: cell)) / cell
        let fv = (v.truncatingRemainder(dividingBy: cell)) / cell
        // Thin gridline near tile borders.
        let border: Float = 0.04
        if fu < border || fu > 1 - border || fv < border || fv > 1 - border {
            return SIMD3(60, 60, 66)
        }
        return checkerIsLight(u: u, v: v, squares: squares)
            ? SIMD3(222, 222, 228)
            : SIMD3(120, 122, 132)
    }

    // MARK: Matcaps

    /// A neutral clay matcap: a sphere lit from the upper-left, sampled as a
    /// disc inscribed in the square (corners transparent).
    public static func clayMatcap(size: Int) -> DebugTexture {
        matcap(size: size) { normal in
            let shade = matcapShade(nx: normal.x, ny: normal.y)
            let base: Float = 0.72
            let value = base * shade
            let c = UInt8(clamp01(value) * 255)
            return SIMD3(c, c, c)
        }
    }

    /// Normal-encoded matcap: the sphere's normal at each texel encoded as
    /// `n*0.5+0.5` RGB — the macOS-14-safe stand-in for a per-pixel normals
    /// pass (RealityKit lacks a public normal-visualisation shader).
    public static func normalMatcap(size: Int) -> DebugTexture {
        matcap(size: size) { normal in
            let c = normalColor(normal)
            return SIMD3(UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255))
        }
    }

    /// Shared matcap rasteriser: for each texel inside the unit disc, computes
    /// the front-facing hemisphere normal and hands it to `shade`. Texels
    /// outside the disc are transparent.
    static func matcap(size: Int, shade: (SIMD3<Float>) -> SIMD3<UInt8>) -> DebugTexture {
        precondition(size > 0, "size must be positive")
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                // Map texel to [-1, 1], flip Y so +Y is up.
                let nx = (Float(x) + 0.5) / Float(size) * 2 - 1
                let ny = 1 - (Float(y) + 0.5) / Float(size) * 2
                let r2 = nx * nx + ny * ny
                guard r2 <= 1 else { continue } // outside disc: transparent
                let nz = (1 - r2).squareRoot()
                let color = shade(SIMD3(nx, ny, nz))
                rgba[i] = color.x; rgba[i + 1] = color.y; rgba[i + 2] = color.z; rgba[i + 3] = 255
            }
        }
        return DebugTexture(width: size, height: size, rgba: rgba)
    }

    /// Lambert-ish shade for a matcap normal lit from the upper-left, with a
    /// constant ambient floor so back-facing texels never go pure black.
    public static func matcapShade(nx: Float, ny: Float) -> Float {
        let light = simd_normalize(SIMD3<Float>(-0.5, 0.6, 0.6))
        let nz = max(0, 1 - nx * nx - ny * ny).squareRoot()
        let ndotl = max(0, simd_dot(SIMD3(nx, ny, nz), light))
        let ambient: Float = 0.35
        return clamp01(ambient + (1 - ambient) * ndotl)
    }

    /// Encodes a (assumed unit) normal as the conventional `n*0.5+0.5` colour.
    public static func normalColor(_ n: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(clamp01(n.x * 0.5 + 0.5), clamp01(n.y * 0.5 + 0.5), clamp01(n.z * 0.5 + 0.5))
    }
}

/// Clamp to 0…1.
func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

/// Pure geometry for the wireframe overlay: the RealityKit layer turns each
/// edge into a thin box (same idiom as the grid), so the edge extraction is
/// unit-testable here.
public enum WireframeGeometry {

    /// The unique undirected edges of a triangle list, each as an ordered
    /// `(low, high)` index pair, de-duplicated across triangles that share an
    /// edge. A trailing partial triangle (index count not a multiple of 3) is
    /// ignored.
    public static func uniqueEdges(triangleIndices: [UInt32]) -> [SIMD2<UInt32>] {
        var seen = Set<UInt64>()
        var edges: [SIMD2<UInt32>] = []
        var i = 0
        while i + 2 < triangleIndices.count {
            let a = triangleIndices[i], b = triangleIndices[i + 1], c = triangleIndices[i + 2]
            for pair in [(a, b), (b, c), (c, a)] {
                let lo = min(pair.0, pair.1), hi = max(pair.0, pair.1)
                let key = UInt64(lo) << 32 | UInt64(hi)
                if seen.insert(key).inserted { edges.append(SIMD2(lo, hi)) }
            }
            i += 3
        }
        return edges
    }
}
