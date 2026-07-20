import Cocoa
import Quartz

/// QuickLook preview (Space-bar / Finder preview pane) for `.usd*` files.
/// Renders a larger auto-framed image via the bundled `usdrecord` runtime and
/// shows it in an aspect-fit image view. Implements `QLPreviewingController`.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView = NSImageView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let image = try await Task.detached(priority: .userInitiated) {
            try QuickLookRenderService.renderImage(source: url, maximumPixelSize: 1024)
        }.value
        await MainActor.run { self.imageView.image = image }
    }
}
