import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode/encode `RGBAImage` to/from PNG bytes. PNG is the recolor pipeline's
/// lossless intermediate (specs/recoloring.md §RecolorEngine step 3) — the
/// engine always works from the highest-quality source and never re-encodes a
/// JPEG generationally. Backed by ImageIO; the decode normalizes any input
/// (indexed, grayscale, 16-bit) to un-premultiplied 8-bit RGBA.
public enum RGBAImageCodec {
    public enum CodecError: Error, Equatable {
        case decodeFailed
        case encodeFailed
    }

    /// Decode image bytes (PNG/JPEG/any ImageIO format) into RGBA8.
    public static func decode(_ data: Data) throws -> RGBAImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CodecError.decodeFailed
        }
        return try decode(cgImage)
    }

    /// Draw a `CGImage` into a known RGBA8 layout so callers get a predictable
    /// buffer regardless of the source's color model or bit depth.
    static func decode(_ cgImage: CGImage) throws -> RGBAImage {
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }) else {
            // coverage:disable — CGContext creation cannot fail for a valid 8-bit RGBA layout with positive dimensions; defensive guard only.
            throw CodecError.decodeFailed
            // coverage:enable
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        unpremultiply(&pixels)
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Encode an `RGBAImage` to PNG bytes.
    public static func encodePNG(_ image: RGBAImage) throws -> Data {
        var pixels = image.pixels
        premultiply(&pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }), let cgImage = context.makeImage() else {
            // coverage:disable — CGContext/makeImage cannot fail for a valid 8-bit RGBA layout; defensive guard only.
            throw CodecError.encodeFailed
            // coverage:enable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            // coverage:disable — the PNG destination for an in-memory CFData is always creatable; defensive guard only.
            throw CodecError.encodeFailed
            // coverage:enable
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            // coverage:disable — finalizing a single valid CGImage to PNG cannot fail; defensive guard only.
            throw CodecError.encodeFailed
            // coverage:enable
        }
        return output as Data
    }

    // Un-premultiply RGBA8 in place (alpha 0 leaves color at 0).
    private static func unpremultiply(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            if a == 0 || a == 255 { continue }
            let alpha = Double(a) / 255.0
            pixels[i] = UInt8(min(255, (Double(pixels[i]) / alpha).rounded()))
            pixels[i + 1] = UInt8(min(255, (Double(pixels[i + 1]) / alpha).rounded()))
            pixels[i + 2] = UInt8(min(255, (Double(pixels[i + 2]) / alpha).rounded()))
        }
    }

    // Premultiply RGBA8 in place.
    private static func premultiply(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            if a == 255 { continue }
            let alpha = Double(a) / 255.0
            pixels[i] = UInt8((Double(pixels[i]) * alpha).rounded())
            pixels[i + 1] = UInt8((Double(pixels[i + 1]) * alpha).rounded())
            pixels[i + 2] = UInt8((Double(pixels[i + 2]) * alpha).rounded())
        }
    }
}
