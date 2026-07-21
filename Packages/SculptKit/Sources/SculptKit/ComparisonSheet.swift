import Foundation

/// A reference-vs-render comparison sheet — img2threejs's "Screenshot-Review
/// Gate" artifact. SculptKit stays free of any imaging framework, so the sheet
/// is emitted as a self-contained SVG that lays the reference image beside the
/// pass render with labels. The agent (or a human) rasterizes/opens it and
/// scores fidelity, then feeds the score + this path back to `sculpt_review`.
public struct ComparisonSheet: Sendable, Equatable {
    public var pass: SculptPass
    public var referencePath: String
    public var renderPath: String
    /// Per-panel pixel size (each image is drawn into a `size`×`size` box).
    public var size: Int

    public init(pass: SculptPass, referencePath: String, renderPath: String, size: Int = 512) {
        self.pass = pass
        self.referencePath = referencePath
        self.renderPath = renderPath
        self.size = max(1, size)
    }

    /// A standalone SVG document placing reference (left) and render (right)
    /// side by side, each labelled. Image hrefs are `file://` URLs so the
    /// sheet resolves the PNGs regardless of the viewer's working directory.
    public func svg() -> String {
        let s = size
        let labelBand = 28
        let width = s * 2
        let height = s + labelBand
        let refHref = Self.fileHref(referencePath)
        let renderHref = Self.fileHref(renderPath)
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <rect width="\(width)" height="\(height)" fill="#1a1a1a"/>
          <image href="\(refHref)" x="0" y="\(labelBand)" width="\(s)" height="\(s)" preserveAspectRatio="xMidYMid meet"/>
          <image href="\(renderHref)" x="\(s)" y="\(labelBand)" width="\(s)" height="\(s)" preserveAspectRatio="xMidYMid meet"/>
          <text x="\(s / 2)" y="20" fill="#eee" font-family="sans-serif" font-size="16" text-anchor="middle">Reference</text>
          <text x="\(s + s / 2)" y="20" fill="#eee" font-family="sans-serif" font-size="16" text-anchor="middle">Render — \(pass.rawValue)</text>
        </svg>
        """
    }

    /// Percent-encode a filesystem path into a `file://` URL, preserving `/`.
    static func fileHref(_ path: String) -> String {
        if path.hasPrefix("file://") { return path }
        let allowed = CharacterSet(charactersIn: "/") .union(.urlPathAllowed)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file://" + encoded
    }
}
