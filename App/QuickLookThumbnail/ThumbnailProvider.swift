import QuickLookThumbnailing
import AppKit

/// Finder / Spotlight / QuickLook thumbnail provider for `.usd/.usda/.usdc/.usdz`.
/// Renders a single auto-framed frame via the bundled `usdrecord` runtime
/// (see `QuickLookRenderService`) and draws it into the requested context.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let maxEdge = Int((max(request.maximumSize.width, request.maximumSize.height)
                           * request.scale).rounded())
        let source = request.fileURL
        do {
            let image = try QuickLookRenderService.renderImage(
                source: source, maximumPixelSize: max(maxEdge, 16))
            let contextSize = request.maximumSize
            let reply = QLThumbnailReply(contextSize: contextSize) { () -> Bool in
                let target = ThumbnailProvider.aspectFitRect(
                    imageSize: image.size, into: contextSize)
                image.draw(in: target)
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }

    /// Aspect-fit `imageSize` centered within `bounds`.
    static func aspectFitRect(imageSize: CGSize, into bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
