import Foundation

/// One reference-vs-render view pair on a comparison sheet: the reference image
/// for an angle beside the render of the same angle, with a label.
public struct ComparisonView: Sendable, Equatable {
    public var label: String
    public var referencePath: String
    public var renderPath: String

    public init(label: String, referencePath: String, renderPath: String) {
        self.label = label
        self.referencePath = referencePath
        self.renderPath = renderPath
    }
}

/// A reference-vs-render comparison sheet — img2threejs's "Screenshot-Review
/// Gate" artifact, generalized to any number of views (a turntable of angles).
/// SculptKit stays free of any imaging framework, so the sheet is emitted as a
/// self-contained SVG: one row per view, reference left and render right. The
/// agent (or a human) rasterizes/opens it and scores fidelity; the measured
/// `ImageSimilarity` for the *worst* view is what the continue-gate enforces.
public struct ComparisonSheet: Sendable, Equatable {
    public var pass: SculptPass
    /// One or more view pairs; multi-view sheets score the worst angle.
    public var views: [ComparisonView]
    /// Per-panel pixel size (each image is drawn into a `size`×`size` box).
    public var size: Int

    /// Multi-view designated initializer.
    public init(pass: SculptPass, views: [ComparisonView], size: Int = 512) {
        self.pass = pass
        self.views = views
        self.size = max(1, size)
    }

    /// Single-view convenience initializer (back-compatible with the original
    /// one-render sheet).
    public init(pass: SculptPass, referencePath: String, renderPath: String, size: Int = 512) {
        self.init(
            pass: pass,
            views: [ComparisonView(label: "view", referencePath: referencePath, renderPath: renderPath)],
            size: size)
    }

    /// A standalone SVG document: a header band plus one row per view, each row
    /// placing reference (left) and render (right) side by side and labelled.
    /// Image hrefs are `file://` URLs so the sheet resolves the PNGs regardless
    /// of the viewer's working directory.
    public func svg() -> String {
        let s = size
        let headerBand = 28
        let rowLabelBand = 22
        let rowHeight = s + rowLabelBand
        let width = s * 2
        let height = headerBand + rowHeight * max(views.count, 1)

        var body = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <rect width="\(width)" height="\(height)" fill="#1a1a1a"/>
          <text x="\(width / 2)" y="19" fill="#eee" font-family="sans-serif" font-size="15" text-anchor="middle" font-weight="bold">Comparison — \(pass.rawValue) (\(views.count) view\(views.count == 1 ? "" : "s"))</text>
        """
        for (index, view) in views.enumerated() {
            let rowTop = headerBand + rowHeight * index
            let imageTop = rowTop + rowLabelBand
            let refHref = Self.fileHref(view.referencePath)
            let renderHref = Self.fileHref(view.renderPath)
            body += """

          <text x="\(s / 2)" y="\(rowTop + 16)" fill="#bbb" font-family="sans-serif" font-size="13" text-anchor="middle">\(Self.escape(view.label)) — reference</text>
          <text x="\(s + s / 2)" y="\(rowTop + 16)" fill="#bbb" font-family="sans-serif" font-size="13" text-anchor="middle">\(Self.escape(view.label)) — render</text>
          <image href="\(refHref)" x="0" y="\(imageTop)" width="\(s)" height="\(s)" preserveAspectRatio="xMidYMid meet"/>
          <image href="\(renderHref)" x="\(s)" y="\(imageTop)" width="\(s)" height="\(s)" preserveAspectRatio="xMidYMid meet"/>
        """
        }
        body += "\n</svg>"
        return body
    }

    /// Minimal XML-text escaping for labels.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Percent-encode a filesystem path into a `file://` URL, preserving `/`.
    static func fileHref(_ path: String) -> String {
        if path.hasPrefix("file://") { return path }
        let allowed = CharacterSet(charactersIn: "/").union(.urlPathAllowed)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file://" + encoded
    }
}
