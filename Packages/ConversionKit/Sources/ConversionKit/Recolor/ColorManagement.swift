import Foundation

// Perceptual color management for the recolor engine (specs/recoloring.md,
// Tier B). Every conversion here is explicit and tagged — the recolor pipeline
// never guesses whether bytes are sRGB-encoded, linear, or Display-P3. All math
// runs in `Double`; callers convert from 8-bit / `Float` at the boundary.
//
// Two perceptual spaces are used, for two different jobs:
//   • OKLab / OKLCh — the *remap* space. Hue/chroma edits happen here because it
//     keeps lightness stable and hue perceptually uniform, so recoloring red
//     leather to blue preserves the grain instead of muddying it.
//   • CIELab (D65) + ΔE*76 — the *measurement* space for the accuracy readout
//     and the golden-image gate (ΔE < 2.0 ≈ a just-noticeable difference).

/// The color space a texture's encoded RGB samples live in. Read from a
/// texture's `sourceColorSpace` where present; otherwise chosen heuristically
/// with a user override (specs/recoloring.md §RecolorEngine step 4).
public enum TextureColorSpace: String, Sendable, CaseIterable, Codable {
    /// sRGB transfer curve over sRGB/Rec.709 primaries (the common albedo case).
    case sRGB
    /// Already-linear light over sRGB primaries (no transfer curve).
    case linear
    /// sRGB transfer curve over Display-P3 primaries (wide-gamut albedo).
    case displayP3
}

/// Linear-light RGB over sRGB (Rec.709) primaries — the engine's hub space.
/// Every texture color space decodes to this before perceptual work, and every
/// output re-encodes from it.
public struct LinearRGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// OKLab (Björn Ottosson, 2020): a perceptual space where Euclidean distance
/// tracks perceived difference and `L` is a stable lightness axis.
public struct OKLab: Hashable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// OKLab in cylindrical form: lightness `L`, chroma `C`, hue `h` (radians).
/// The recolor remap is expressed here — set hue, scale chroma, keep lightness.
public struct OKLCh: Hashable, Sendable {
    public var L: Double
    public var C: Double
    /// Hue angle in radians, normalized to [0, 2π).
    public var h: Double

    public init(L: Double, C: Double, h: Double) {
        self.L = L
        self.C = C
        self.h = h
    }
}

/// CIELab (D65). Used only for the ΔE*76 accuracy metric and its golden gate.
public struct CIELab: Hashable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// sRGB opto-electronic transfer functions (IEC 61966-2-1). Shared by sRGB and
/// Display-P3 (P3 differs only in primaries, not in the transfer curve).
public enum ColorTransfer {
    /// Encoded sRGB component in [0,1] → linear light.
    public static func sRGBToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light → encoded sRGB component in [0,1].
    public static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }
}

public extension OKLab {
    /// Linear sRGB → OKLab.
    init(linear c: LinearRGB) {
        let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
        let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
        let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
        let l_ = Foundation.cbrt(l)
        let m_ = Foundation.cbrt(m)
        let s_ = Foundation.cbrt(s)
        self.init(
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }
}

public extension LinearRGB {
    /// OKLab → linear sRGB.
    init(oklab c: OKLab) {
        let l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        self.init(
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }
}

public extension OKLCh {
    /// OKLab → OKLCh. Hue is normalized to [0, 2π).
    init(oklab c: OKLab) {
        let chroma = (c.a * c.a + c.b * c.b).squareRoot()
        var hue = atan2(c.b, c.a)
        if hue < 0 { hue += 2 * .pi }
        self.init(L: c.L, C: chroma, h: hue)
    }
}

public extension OKLab {
    /// OKLCh → OKLab.
    init(oklch c: OKLCh) {
        self.init(L: c.L, a: c.C * Foundation.cos(c.h), b: c.C * Foundation.sin(c.h))
    }
}

public extension CIELab {
    /// Linear sRGB (D65) → CIELab, via CIE XYZ.
    init(linear c: LinearRGB) {
        let x = 0.4124564 * c.r + 0.3575761 * c.g + 0.1804375 * c.b
        let y = 0.2126729 * c.r + 0.7151522 * c.g + 0.0721750 * c.b
        let z = 0.0193339 * c.r + 0.1191920 * c.g + 0.9503041 * c.b
        // D65 reference white.
        let fx = CIELab.f(x / 0.95047)
        let fy = CIELab.f(y / 1.0)
        let fz = CIELab.f(z / 1.08883)
        self.init(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func f(_ t: Double) -> Double {
        let d: Double = 6.0 / 29.0
        return t > d * d * d ? Foundation.cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
    }
}

/// CIELab ΔE*76 (Euclidean). ΔE < ~2.0 is a just-noticeable difference — the
/// threshold the calibrated-accuracy golden gate uses.
public func deltaE76(_ x: CIELab, _ y: CIELab) -> Double {
    let dL = x.L - y.L
    let da = x.a - y.a
    let db = x.b - y.b
    return (dL * dL + da * da + db * db).squareRoot()
}

/// Decoding/encoding between a tagged texture color space and the linear-sRGB
/// hub. Display-P3 goes through the linear P3 ↔ linear sRGB primary matrices.
public enum ColorManagement {
    // Linear Display-P3 → linear sRGB.
    private static func p3ToSRGB(_ c: LinearRGB) -> LinearRGB {
        LinearRGB(
            r: 1.2249401762 * c.r - 0.2249404157 * c.g + 0.0000002385 * c.b,
            g: -0.0420569547 * c.r + 1.0420571660 * c.g - 0.0000002115 * c.b,
            b: -0.0196375546 * c.r - 0.0786360454 * c.g + 1.0982736000 * c.b
        )
    }

    // Linear sRGB → linear Display-P3.
    private static func sRGBToP3(_ c: LinearRGB) -> LinearRGB {
        LinearRGB(
            r: 0.8224621999 * c.r + 0.1775380001 * c.g,
            g: 0.0331941989 * c.r + 0.9668058011 * c.g,
            b: 0.0170826307 * c.r + 0.0723974407 * c.g + 0.9105199286 * c.b
        )
    }

    /// Encoded RGB (components in [0,1]) in `space` → linear sRGB hub.
    public static func decode(_ rgb: (r: Double, g: Double, b: Double), from space: TextureColorSpace) -> LinearRGB {
        switch space {
        case .linear:
            return LinearRGB(r: rgb.r, g: rgb.g, b: rgb.b)
        case .sRGB:
            return LinearRGB(
                r: ColorTransfer.sRGBToLinear(rgb.r),
                g: ColorTransfer.sRGBToLinear(rgb.g),
                b: ColorTransfer.sRGBToLinear(rgb.b)
            )
        case .displayP3:
            let linP3 = LinearRGB(
                r: ColorTransfer.sRGBToLinear(rgb.r),
                g: ColorTransfer.sRGBToLinear(rgb.g),
                b: ColorTransfer.sRGBToLinear(rgb.b)
            )
            return p3ToSRGB(linP3)
        }
    }

    /// Linear sRGB hub → encoded RGB (components clamped to [0,1]) in `space`.
    public static func encode(_ c: LinearRGB, to space: TextureColorSpace) -> (r: Double, g: Double, b: Double) {
        switch space {
        case .linear:
            return (clamp01(c.r), clamp01(c.g), clamp01(c.b))
        case .sRGB:
            return (
                clamp01(ColorTransfer.linearToSRGB(c.r)),
                clamp01(ColorTransfer.linearToSRGB(c.g)),
                clamp01(ColorTransfer.linearToSRGB(c.b))
            )
        case .displayP3:
            let linP3 = sRGBToP3(c)
            return (
                clamp01(ColorTransfer.linearToSRGB(linP3.r)),
                clamp01(ColorTransfer.linearToSRGB(linP3.g)),
                clamp01(ColorTransfer.linearToSRGB(linP3.b))
            )
        }
    }

    /// Parse a `#RRGGBB` (or `RRGGBB`) hex string into encoded sRGB components
    /// in [0,1]. Returns nil for malformed input.
    public static func parseHexSRGB(_ text: String) -> (r: Double, g: Double, b: Double)? {
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        hex = hex.uppercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let value = UInt32(hex, radix: 16)!
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }

    static func clamp01(_ x: Double) -> Double {
        x < 0 ? 0 : (x > 1 ? 1 : x)
    }
}
