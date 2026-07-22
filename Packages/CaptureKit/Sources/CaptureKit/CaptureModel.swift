import Foundation

/// Reconstruction fidelity tier requested from the capture pipeline. Maps 1:1
/// onto `PhotogrammetrySession.Request.Detail` (the mapping lives here so the
/// planner stays pure and the ConversionKit seam never re-derives it).
///
/// The material each tier produces is honest and explicit: lower tiers are
/// diffuse-only, and only `.full`/`.raw` author a full `UsdPreviewSurface`
/// metallic-roughness map set (specs/capture-import.md — Detail → session mapping).
public enum CaptureDetail: String, Sendable, Codable, CaseIterable {
    case preview
    case reduced
    case medium
    case full
    case raw

    /// The `PhotogrammetrySession` detail token this tier resolves to. Identical
    /// to `rawValue` today, but expressed separately so the session vocabulary
    /// can diverge from our public enum without touching call sites.
    public var sessionToken: String { rawValue }

    /// `true` when the tier authors a full PBR map set (baseColor + normal + AO
    /// + roughness). Only `.full`/`.raw` qualify; lower tiers are diffuse-only.
    public var requestsPBRMaps: Bool {
        switch self {
        case .preview, .reduced, .medium: return false
        case .full, .raw: return true
        }
    }

    /// `true` when the tier authors a tangent-space normal map. `.medium` gains
    /// a normal map on top of its diffuse base; `.full`/`.raw` author the whole set.
    public var authorsNormalMap: Bool {
        switch self {
        case .preview, .reduced: return false
        case .medium, .full, .raw: return true
        }
    }

    /// Plain-language description of the material a tier yields, surfaced in the
    /// UI/CLI so a user is never surprised by a flat diffuse-only result.
    public var materialSummary: String {
        switch self {
        case .preview, .reduced: return "diffuse only"
        case .medium: return "diffuse + normal"
        case .full: return "baseColor + normal + AO + roughness"
        case .raw: return "full PBR map set (max fidelity)"
        }
    }
}

/// Compliance profile a finished capture is gated against downstream. A local,
/// dependency-free mirror of ValidationKit's profile identifiers: the leaf must
/// not import ValidationKit, so it carries only the identifier and the consuming
/// layer (CLI/EditorUI) resolves it to a `ValidationProfile`.
public enum CaptureProfile: String, Sendable, Codable, CaseIterable {
    case arkit
    case arkitStrict

    /// The ValidationKit profile identifier this maps to (`arkit` / `arkit-strict`).
    public var validationIdentifier: String {
        switch self {
        case .arkit: return "arkit"
        case .arkitStrict: return "arkit-strict"
        }
    }
}

/// Pixel dimensions of a source image. Supplied by the caller (who decodes the
/// image headers) so the planner's resolution check stays a pure function of its
/// inputs rather than reaching for ImageIO inside the leaf.
public struct PixelSize: Sendable, Codable, Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A request to reconstruct a mesh from a folder of photographs. Pure value
/// type: `imageURLs` are the ordered source photos, `detail` the fidelity tier,
/// `targetMetersPerUnit` an optional absolute-scale target that chains into the
/// existing `ScaleFixer` post-import, and `profile` the downstream export gate.
public struct CaptureRequest: Sendable, Codable, Equatable {
    public var imageURLs: [URL]
    public var detail: CaptureDetail
    public var targetMetersPerUnit: Double?
    public var profile: CaptureProfile

    public init(
        imageURLs: [URL],
        detail: CaptureDetail = .medium,
        targetMetersPerUnit: Double? = nil,
        profile: CaptureProfile = .arkit
    ) {
        self.imageURLs = imageURLs
        self.detail = detail
        self.targetMetersPerUnit = targetMetersPerUnit
        self.profile = profile
    }
}
