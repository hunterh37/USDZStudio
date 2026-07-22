import Foundation

/// The ordered stages a capture import runs through. A `BuildStep`-style
/// declarative list so the ConversionKit importer realizes exactly this sequence
/// (specs/capture-import.md — Pipeline model).
public enum CaptureStageID: String, Sendable, Codable, CaseIterable {
    /// Pure pre-flight: build the `CaptureQualityReport`; blocking issues stop here.
    case validate
    /// The injected reconstruction seam (`PhotogrammetrySession`). Non-deterministic.
    case session
    /// Open the produced USDZ, assert Y-up, optional `ScaleFixer`, naming fixes.
    case normalize
    /// Run the compliance profile and surface advisories; never auto-launder.
    case validateOutput
}

/// A deterministic, ordered plan for one capture. Produced purely from a
/// `CaptureRequest`; the same request always yields the same plan (golden-tested).
public struct CapturePlan: Sendable, Codable, Equatable {
    /// The stages to run, in order.
    public let stages: [CaptureStageID]
    /// The resolved `PhotogrammetrySession` detail token (e.g. "medium").
    public let sessionDetail: String
    /// `true` when the session should request the full PBR map set.
    public let requestsPBRMaps: Bool

    public init(stages: [CaptureStageID], sessionDetail: String, requestsPBRMaps: Bool) {
        self.stages = stages
        self.sessionDetail = sessionDetail
        self.requestsPBRMaps = requestsPBRMaps
    }
}
