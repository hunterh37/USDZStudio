import Foundation

/// A decoded, un-premultiplied 8-bit RGBA raster, row-major. The recolor
/// engine's working buffer: color-space handling is explicit and lives in the
/// engine, so the raster itself carries no color-space tag — just samples.
public struct RGBAImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, row-major, R,G,B,A per pixel.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "RGBAImage requires positive dimensions")
        precondition(pixels.count == width * height * 4, "RGBAImage pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A solid-fill image (handy for tests and calibration swatches).
    public init(width: Int, height: Int, fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: buffer.count, by: 4) {
            buffer[i] = fill.r
            buffer[i + 1] = fill.g
            buffer[i + 2] = fill.b
            buffer[i + 3] = fill.a
        }
        self.init(width: width, height: height, pixels: buffer)
    }

    public var pixelCount: Int { width * height }

    /// Byte offset of pixel `(x, y)`'s red channel.
    func offset(x: Int, y: Int) -> Int {
        (y * width + x) * 4
    }

    /// Read pixel `(x, y)` as RGBA bytes.
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let o = offset(x: x, y: y)
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
    }

    /// Write pixel `(x, y)`.
    public mutating func setPixel(x: Int, y: Int, to c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        let o = offset(x: x, y: y)
        pixels[o] = c.r
        pixels[o + 1] = c.g
        pixels[o + 2] = c.b
        pixels[o + 3] = c.a
    }
}

/// A per-pixel selection weight in [0,1] over an image, row-major. `1` = fully
/// recolored, `0` = untouched; fractional values feather a mask edge.
public struct RecolorMask: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height` weights, row-major.
    public var coverage: [Double]

    public init(width: Int, height: Int, coverage: [Double]) {
        precondition(width > 0 && height > 0, "RecolorMask requires positive dimensions")
        precondition(coverage.count == width * height, "RecolorMask coverage size mismatch")
        self.width = width
        self.height = height
        self.coverage = coverage
    }

    /// A mask selecting every pixel fully.
    public static func full(width: Int, height: Int) -> RecolorMask {
        RecolorMask(width: width, height: height, coverage: [Double](repeating: 1, count: width * height))
    }

    public func weight(x: Int, y: Int) -> Double {
        coverage[y * width + x]
    }
}
