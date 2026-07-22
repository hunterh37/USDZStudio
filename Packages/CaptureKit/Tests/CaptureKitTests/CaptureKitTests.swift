import Testing
import Foundation
@testable import CaptureKit

/// Helper: N synthetic image URLs with a given extension.
private func imageURLs(_ n: Int, ext: String = "heic") -> [URL] {
    (0..<n).map { URL(fileURLWithPath: "/tmp/capture/img_\(String(format: "%03d", $0)).\(ext)") }
}

@Suite("CaptureDetail → session mapping")
struct CaptureDetailTests {
    @Test func sessionTokenMatchesRawValue() {
        for detail in CaptureDetail.allCases {
            #expect(detail.sessionToken == detail.rawValue)
        }
    }

    @Test func pbrMapsOnlyForFullAndRaw() {
        // Exhaustive assertion of the detail → PBR table (specs/capture-import.md).
        #expect(CaptureDetail.preview.requestsPBRMaps == false)
        #expect(CaptureDetail.reduced.requestsPBRMaps == false)
        #expect(CaptureDetail.medium.requestsPBRMaps == false)
        #expect(CaptureDetail.full.requestsPBRMaps == true)
        #expect(CaptureDetail.raw.requestsPBRMaps == true)
    }

    @Test func normalMapFromMediumUp() {
        #expect(CaptureDetail.preview.authorsNormalMap == false)
        #expect(CaptureDetail.reduced.authorsNormalMap == false)
        #expect(CaptureDetail.medium.authorsNormalMap == true)
        #expect(CaptureDetail.full.authorsNormalMap == true)
        #expect(CaptureDetail.raw.authorsNormalMap == true)
    }

    @Test func materialSummaryIsHonestPerTier() {
        #expect(CaptureDetail.preview.materialSummary == "diffuse only")
        #expect(CaptureDetail.reduced.materialSummary == "diffuse only")
        #expect(CaptureDetail.medium.materialSummary == "diffuse + normal")
        #expect(CaptureDetail.full.materialSummary == "baseColor + normal + AO + roughness")
        #expect(CaptureDetail.raw.materialSummary == "full PBR map set (max fidelity)")
    }

    @Test func codableRoundTrip() throws {
        for detail in CaptureDetail.allCases {
            let data = try JSONEncoder().encode(detail)
            #expect(try JSONDecoder().decode(CaptureDetail.self, from: data) == detail)
        }
    }
}

@Suite("CaptureProfile")
struct CaptureProfileTests {
    @Test func validationIdentifiers() {
        #expect(CaptureProfile.arkit.validationIdentifier == "arkit")
        #expect(CaptureProfile.arkitStrict.validationIdentifier == "arkit-strict")
    }

    @Test func codableRoundTrip() throws {
        for profile in CaptureProfile.allCases {
            let data = try JSONEncoder().encode(profile)
            #expect(try JSONDecoder().decode(CaptureProfile.self, from: data) == profile)
        }
    }
}

@Suite("PixelSize")
struct PixelSizeTests {
    @Test func equalityAndHashing() {
        let a = PixelSize(width: 4032, height: 3024)
        let b = PixelSize(width: 4032, height: 3024)
        let c = PixelSize(width: 1920, height: 1080)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func codableRoundTrip() throws {
        let size = PixelSize(width: 100, height: 200)
        let data = try JSONEncoder().encode(size)
        #expect(try JSONDecoder().decode(PixelSize.self, from: data) == size)
    }
}

@Suite("CaptureRequest")
struct CaptureRequestTests {
    @Test func defaultsAndCodableRoundTrip() throws {
        let request = CaptureRequest(imageURLs: imageURLs(3))
        #expect(request.detail == .medium)
        #expect(request.profile == .arkit)
        #expect(request.targetMetersPerUnit == nil)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(CaptureRequest.self, from: data) == request)
    }

    @Test func explicitValues() {
        let request = CaptureRequest(
            imageURLs: imageURLs(60), detail: .raw,
            targetMetersPerUnit: 0.5, profile: .arkitStrict)
        #expect(request.detail == .raw)
        #expect(request.targetMetersPerUnit == 0.5)
        #expect(request.profile == .arkitStrict)
    }
}

@Suite("CaptureIssue")
struct CaptureIssueTests {
    @Test func blockingClassification() {
        #expect(CaptureIssue.tooFewImages(count: 1, minimum: 20).isBlocking)
        #expect(CaptureIssue.mixedResolution.isBlocking)
        #expect(CaptureIssue.unsupportedImageFormat(URL(fileURLWithPath: "/x.gif")).isBlocking)
        #expect(CaptureIssue.lowOverlapHint.isBlocking == false)
    }

    @Test func messagesAreActionable() {
        #expect(CaptureIssue.tooFewImages(count: 1, minimum: 20).message.contains("only 1 image"))
        #expect(CaptureIssue.tooFewImages(count: 3, minimum: 20).message.contains("3 images"))
        #expect(CaptureIssue.mixedResolution.message.contains("mixed resolutions"))
        #expect(CaptureIssue.lowOverlapHint.message.contains("overlapping angles"))
        #expect(CaptureIssue.unsupportedImageFormat(URL(fileURLWithPath: "/tmp/x.gif"))
            .message.contains("x.gif"))
    }
}

@Suite("CaptureQualityReport")
struct CaptureQualityReportTests {
    @Test func acceptableWhenNoBlocking() {
        let report = CaptureQualityReport(issues: [.lowOverlapHint])
        #expect(report.isAcceptable)
        #expect(report.advisories.count == 1)
        #expect(report.blockingIssues.isEmpty)
    }

    @Test func unacceptableWithBlocking() {
        let report = CaptureQualityReport(issues: [.mixedResolution, .lowOverlapHint])
        #expect(report.isAcceptable == false)
        #expect(report.blockingIssues == [.mixedResolution])
        #expect(report.advisories == [.lowOverlapHint])
    }

    @Test func emptyIsAcceptable() {
        #expect(CaptureQualityReport(issues: []).isAcceptable)
    }
}

@Suite("CaptureStageID / CapturePlan")
struct CapturePlanTypeTests {
    @Test func stageOrder() {
        #expect(CaptureStageID.allCases == [.validate, .session, .normalize, .validateOutput])
    }

    @Test func planCodableRoundTrip() throws {
        let plan = CapturePlan(stages: CaptureStageID.allCases, sessionDetail: "full", requestsPBRMaps: true)
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(CapturePlan.self, from: data) == plan)
    }
}

@Suite("CapturePlanner — validate")
struct CapturePlannerValidateTests {
    let planner = CapturePlanner()

    @Test func acceptsAmpleCapture() {
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(60)))
        #expect(report.isAcceptable)
        #expect(report.issues.isEmpty)
    }

    @Test func advisesNearMinimum() {
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(30)))
        #expect(report.isAcceptable)
        #expect(report.issues == [.lowOverlapHint])
    }

    @Test func advisoryFiresExactlyAtMinimum() {
        // Boundary: exactly `minimumImages` clears the floor but is still advised.
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(20)))
        #expect(report.issues == [.lowOverlapHint])
    }

    @Test func noAdvisoryAtAdvisoryCeiling() {
        // Boundary: exactly `advisoryImages` is comfortable — no advisory.
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(50)))
        #expect(report.issues.isEmpty)
    }

    @Test func blocksTooFewImages() {
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(5)))
        #expect(report.isAcceptable == false)
        #expect(report.issues == [.tooFewImages(count: 5, minimum: 20)])
    }

    @Test func blocksUnsupportedFormat() {
        var urls = imageURLs(60)
        urls.append(URL(fileURLWithPath: "/tmp/capture/notes.gif"))
        let report = planner.validate(CaptureRequest(imageURLs: urls))
        #expect(report.blockingIssues == [.unsupportedImageFormat(URL(fileURLWithPath: "/tmp/capture/notes.gif"))])
    }

    @Test func blocksMixedResolution() {
        let sizes = [PixelSize(width: 4032, height: 3024), PixelSize(width: 1920, height: 1080)]
            + Array(repeating: PixelSize(width: 4032, height: 3024), count: 58)
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(60)), imageResolutions: sizes)
        #expect(report.blockingIssues == [.mixedResolution])
    }

    @Test func uniformResolutionIsClean() {
        let sizes = Array(repeating: PixelSize(width: 4032, height: 3024), count: 60)
        let report = planner.validate(CaptureRequest(imageURLs: imageURLs(60)), imageResolutions: sizes)
        #expect(report.issues.isEmpty)
    }

    @Test func acceptsAllSupportedExtensionsCaseInsensitively() {
        let urls = ["HEIC", "heif", "JPG", "jpeg", "PNG"].enumerated().map {
            URL(fileURLWithPath: "/tmp/img_\($0.offset).\($0.element)")
        }
        // Only 5 images → too few, but no unsupported-format issue.
        let report = planner.validate(CaptureRequest(imageURLs: urls))
        #expect(report.issues.contains(.tooFewImages(count: 5, minimum: 20)))
        #expect(!report.issues.contains { if case .unsupportedImageFormat = $0 { return true }; return false })
    }

    // Property: removing images never *clears* a blocking issue (monotonicity).
    @Test func removingImagesNeverClearsBlocking() {
        var urls = imageURLs(25)
        var wasBlocked = !planner.validate(CaptureRequest(imageURLs: urls)).isAcceptable
        // Start acceptable (25 images), then peel down; once blocked, stays blocked.
        while urls.count > 1 {
            urls.removeLast()
            let acceptable = planner.validate(CaptureRequest(imageURLs: urls)).isAcceptable
            if wasBlocked { #expect(acceptable == false) }
            if !acceptable { wasBlocked = true }
        }
        #expect(wasBlocked)
    }
}

@Suite("CapturePlanner — plan")
struct CapturePlannerPlanTests {
    let planner = CapturePlanner()

    @Test func deterministic() {
        let request = CaptureRequest(imageURLs: imageURLs(60), detail: .full)
        #expect(planner.plan(request) == planner.plan(request))
    }

    @Test func stagesAreTheFullOrderedSequence() {
        let plan = planner.plan(CaptureRequest(imageURLs: imageURLs(60)))
        #expect(plan.stages == [.validate, .session, .normalize, .validateOutput])
    }

    @Test func detailDrivesSessionTokenAndPBR() {
        for detail in CaptureDetail.allCases {
            let plan = planner.plan(CaptureRequest(imageURLs: imageURLs(60), detail: detail))
            #expect(plan.sessionDetail == detail.sessionToken)
            #expect(plan.requestsPBRMaps == detail.requestsPBRMaps)
        }
    }

    // Golden CapturePlan JSON per detail level (pinned wire shape).
    @Test func goldenPlanJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let golden: [CaptureDetail: String] = [
            .preview: #"{"requestsPBRMaps":false,"sessionDetail":"preview","stages":["validate","session","normalize","validateOutput"]}"#,
            .reduced: #"{"requestsPBRMaps":false,"sessionDetail":"reduced","stages":["validate","session","normalize","validateOutput"]}"#,
            .medium: #"{"requestsPBRMaps":false,"sessionDetail":"medium","stages":["validate","session","normalize","validateOutput"]}"#,
            .full: #"{"requestsPBRMaps":true,"sessionDetail":"full","stages":["validate","session","normalize","validateOutput"]}"#,
            .raw: #"{"requestsPBRMaps":true,"sessionDetail":"raw","stages":["validate","session","normalize","validateOutput"]}"#,
        ]
        for (detail, expected) in golden {
            let plan = planner.plan(CaptureRequest(imageURLs: imageURLs(60), detail: detail))
            let json = String(decoding: try encoder.encode(plan), as: UTF8.self)
            #expect(json == expected)
        }
    }

    @Test func customThresholdsHonored() {
        let strict = CapturePlanner(minimumImages: 40, advisoryImages: 80)
        #expect(strict.validate(CaptureRequest(imageURLs: imageURLs(30))).blockingIssues
            == [.tooFewImages(count: 30, minimum: 40)])
        #expect(strict.validate(CaptureRequest(imageURLs: imageURLs(60))).issues == [.lowOverlapHint])
    }

    @Test func protocolConvenienceOverloadSkipsResolution() {
        // The extension overload forwards nil resolutions — no mixed-resolution issue.
        let planner: CapturePlanning = CapturePlanner()
        #expect(planner.validate(CaptureRequest(imageURLs: imageURLs(60))).issues.isEmpty)
    }
}
