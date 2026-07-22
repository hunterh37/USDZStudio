import Foundation
import SculptKit
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Decodes image files into `SculptKit.RasterImage` (RGBA8) so the pure
/// similarity metric can run on real render/reference pixels. This is the one
/// place the sculpt pipeline touches an imaging framework — SculptKit itself
/// stays decode-free. On platforms without ImageIO the loader returns nil and
/// the similarity floor degrades to a no-op (the subjective score still gates).
public enum RasterLoader {
    /// Basic decoded facts about an image, without the full pixel buffer — used
    /// by the probe/assess intake to derive true dimensions and alpha.
    public struct ImageInfo: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var hasAlpha: Bool
    }

    #if canImport(ImageIO)
    /// Decode an image file at `path` into an RGBA8 `RasterImage`. Returns nil
    /// when the file is missing, undecodable, or has non-positive dimensions.
    public static func load(path: String) -> RasterImage? {
        guard let cg = decodeCGImage(path: path) else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo)
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RasterImage(width: width, height: height, rgba: buffer)
    }

    /// Read an image's dimensions and alpha without decoding the pixels.
    public static func info(path: String) -> ImageInfo? {
        guard let source = imageSource(path: path),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        return ImageInfo(width: width, height: height, hasAlpha: hasAlpha)
    }

    static func imageSource(path: String) -> CGImageSource? {
        let url = URL(fileURLWithPath: path) as CFURL
        return CGImageSourceCreateWithURL(url, nil)
    }

    static func decodeCGImage(path: String) -> CGImage? {
        guard let source = imageSource(path: path) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    #else
    // coverage:disable — non-Apple fallback; the project targets macOS, so ImageIO is always present in CI.
    public static func load(path: String) -> RasterImage? { nil }
    public static func info(path: String) -> ImageInfo? { nil }
    // coverage:enable
    #endif

    /// Load a *reference* image for comparison, matting it first when it is
    /// opaque (sculpt-accuracy P1/#82). Finding F1: a raw photo's busy opaque
    /// background dominates the measured similarity (IoU 0.166 raw vs 0.420
    /// matted on the same reference), so an opaque reference is segmented and
    /// its background made transparent before the metric sees it. References
    /// that already carry alpha (pre-matted, or synthetic renders) pass through
    /// untouched, and a matte that finds no foreground at all falls back to the
    /// raw pixels rather than erasing the reference.
    public static func loadReference(path: String) -> RasterImage? {
        guard let raw = load(path: path) else { return nil }
        return mattedReference(raw)
    }

    /// The matting policy for `loadReference`, factored out so the pure
    /// decision (alpha passthrough / matte / empty-matte fallback) is testable
    /// without touching the filesystem.
    static func mattedReference(_ raw: RasterImage) -> RasterImage {
        guard !ReferenceMatte.hasMeaningfulAlpha(raw) else { return raw }
        let mask = ReferenceMatte.segment(raw)
        guard mask.alpha.contains(where: { $0 > 0 }) else { return raw }
        var rgba = raw.rgba
        for i in 0..<(raw.width * raw.height) {
            rgba[i * 4 + 3] = mask.alpha[i]
        }
        // Safe: identical dimensions and buffer length to `raw`.
        return RasterImage(width: raw.width, height: raw.height, rgba: rgba)!
    }

    /// Decode a reference/render pair and compute their similarity. Returns nil
    /// when either image fails to decode, so callers can distinguish "measured
    /// low" from "could not measure". The reference side goes through the
    /// P1 matting policy (`loadReference`).
    public static func similarity(referencePath: String, renderPath: String) -> SimilarityReport? {
        guard let reference = loadReference(path: referencePath),
              let render = load(path: renderPath) else { return nil }
        return ImageSimilarity.compare(reference: reference, render: render)
    }

    /// Decode a set of labelled reference/render view pairs and return the
    /// worst-view similarity (nil if the set is empty or any image fails).
    public static func worstViewSimilarity(
        _ views: [(reference: String, render: String)]
    ) -> SimilarityReport? {
        guard !views.isEmpty else { return nil }
        var pairs: [(reference: RasterImage, render: RasterImage)] = []
        for view in views {
            guard let reference = loadReference(path: view.reference),
                  let render = load(path: view.render) else { return nil }
            pairs.append((reference, render))
        }
        return ImageSimilarity.worstView(pairs)
    }
}
