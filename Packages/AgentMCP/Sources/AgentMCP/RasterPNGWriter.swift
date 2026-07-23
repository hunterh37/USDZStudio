import Foundation
import SculptKit
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

/// Encodes a `SculptKit.RasterImage` (RGBA8) to a PNG file on disk. The inverse
/// of `RasterLoader`, and the one place the facade-bake path touches an imaging
/// framework — SculptKit stays codec-free and produces only raw pixel buffers.
public enum RasterPNGWriter {
    public enum WriteError: Error, Equatable {
        case contextCreationFailed
        case imageCreationFailed
        case destinationCreationFailed
        case finalizeFailed
    }

    #if canImport(ImageIO)
    /// Write `image` to `url` as a PNG. Creates parent directories as needed.
    public static func write(_ image: RasterImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var buffer = image.rgba
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo)
        }) else { throw WriteError.contextCreationFailed }
        guard let cg = ctx.makeImage() else { throw WriteError.imageCreationFailed }

        let type = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw WriteError.destinationCreationFailed
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.finalizeFailed }
    }
    #else
    // coverage:disable — non-Apple fallback; the project targets macOS, so ImageIO is always present in CI.
    public static func write(_ image: RasterImage, to url: URL) throws {
        throw WriteError.destinationCreationFailed
    }
    // coverage:enable
    #endif
}
