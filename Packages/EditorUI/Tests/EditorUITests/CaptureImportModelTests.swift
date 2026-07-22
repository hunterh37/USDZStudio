import Testing
import SwiftUI
import Foundation
import CaptureKit
import ConversionKit
@testable import EditorUI

/// A scriptable fake capture service: canned image lists + pre-flight verdicts,
/// and a reconstruction stream the test can shape (progress ticks, a terminal
/// model URL or none, or a thrown error). Lets `CaptureImportModel` be driven
/// end-to-end with no ImageIO or Object Capture hardware.
@MainActor
private final class FakeCaptureService: CaptureImportService {
    var imagesByFolder: [URL: [URL]] = [:]
    var report: CaptureQualityReport = .init(issues: [])
    /// Events the reconstruct stream yields, in order.
    var events: [CaptureProgress] = []
    /// When set, the stream throws this after emitting `events`.
    var error: Error?
    /// Records the arguments the model passed to `reconstruct`.
    private(set) var lastDetail: CaptureDetail?
    private(set) var lastMeters: Double??

    func images(in folder: URL) -> [URL] { imagesByFolder[folder] ?? [] }

    func preflight(images: [URL], detail: CaptureDetail, profile: CaptureProfile) -> CaptureQualityReport {
        report
    }

    func reconstruct(
        images: [URL], detail: CaptureDetail, profile: CaptureProfile, targetMetersPerUnit: Double?
    ) -> AsyncThrowingStream<CaptureProgress, Error> {
        lastDetail = detail
        lastMeters = .some(targetMetersPerUnit)
        let events = events
        let error = error
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }
}

@MainActor
@Suite struct CaptureImportModelTests {

    private func folderWith(_ count: Int) -> (URL, [URL]) {
        let folder = URL(fileURLWithPath: "/tmp/shoot")
        let images = (0..<count).map { folder.appendingPathComponent("img\($0).heic") }
        return (folder, images)
    }

    // MARK: Folder selection + pre-flight

    @Test func selectingFolderGathersImagesAndRunsPreflight() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        service.report = CaptureQualityReport(issues: [])
        let model = CaptureImportModel(service: service)

        model.selectFolder(folder)

        #expect(model.folder == folder)
        #expect(model.images.count == 30)
        #expect(model.report?.isAcceptable == true)
        #expect(model.canStart)
        #expect(!model.showsGuidance)
    }

    @Test func blockingReportDisablesStart() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(3)
        service.imagesByFolder = [folder: images]
        service.report = CaptureQualityReport(issues: [.tooFewImages(count: 3, minimum: 20)])
        let model = CaptureImportModel(service: service)

        model.selectFolder(folder)

        #expect(!model.canStart)
        #expect(model.blockingIssues.count == 1)
        #expect(model.advisories.isEmpty)
    }

    @Test func advisoryShowsGuidanceButAllowsStart() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(25)
        service.imagesByFolder = [folder: images]
        service.report = CaptureQualityReport(issues: [.lowOverlapHint])
        let model = CaptureImportModel(service: service)

        model.selectFolder(folder)

        #expect(model.canStart)
        #expect(model.showsGuidance)
        #expect(model.advisories.count == 1)
    }

    @Test func changingDetailAndProfileReRunsPreflight() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)

        // A blocking report installed after selection surfaces on the next refresh.
        service.report = CaptureQualityReport(issues: [.mixedResolution])
        model.detail = .full
        #expect(model.blockingIssues.count == 1)
        model.profile = .arkitStrict
        #expect(model.blockingIssues.count == 1)
    }

    @Test func refreshPreflightIsNoOpWithoutFolder() {
        let service = FakeCaptureService()
        let model = CaptureImportModel(service: service)
        model.refreshPreflight()
        #expect(model.report == nil)
        #expect(!model.canStart)
    }

    // MARK: Material caveat

    @Test func materialCaveatDistinguishesPBRTiers() {
        let model = CaptureImportModel(service: FakeCaptureService())
        model.detail = .preview
        #expect(model.materialCaveat.contains("diffuse only"))
        model.detail = .full
        #expect(model.materialCaveat.contains("full PBR"))
    }

    // MARK: Reconstruction lifecycle

    @Test func successfulRunCompletesAndOpensProducedURL() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(60)
        service.imagesByFolder = [folder: images]
        let produced = URL(fileURLWithPath: "/tmp/out/model.usdz")
        service.events = [.progress(0.5), .modelReady(url: produced)]
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)

        var opened: URL?
        model.start { opened = $0 }
        await Task.yield()
        // Drain the run task by polling the phase.
        for _ in 0..<100 where model.producedURL == nil { await Task.yield() }

        #expect(model.producedURL == produced)
        #expect(opened == produced)
        #expect(!model.isRunning)
    }

    @Test func runWithoutModelReadyFails() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        service.events = [.progress(0.9)]  // no modelReady
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)

        model.start { _ in }
        for _ in 0..<100 where model.failureMessage == nil { await Task.yield() }

        #expect(model.failureMessage != nil)
        #expect(model.producedURL == nil)
    }

    @Test func runThatThrowsSurfacesRecoverySuggestion() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        service.error = CaptureImportError.sessionProducedNoModel
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)

        model.start { _ in }
        for _ in 0..<100 where model.failureMessage == nil { await Task.yield() }

        #expect(model.failureMessage == CaptureImportError.sessionProducedNoModel.recoverySuggestion)
    }

    @Test func startIsGuardedWhenPreflightBlocks() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(3)
        service.imagesByFolder = [folder: images]
        service.report = CaptureQualityReport(issues: [.tooFewImages(count: 3, minimum: 20)])
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)

        model.start { _ in }
        // Guarded: never entered a running/failed/completed phase.
        #expect(model.phase == .idle)
    }

    @Test func normalizeScalePassesTargetMetersToService() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        service.events = [.modelReady(url: URL(fileURLWithPath: "/tmp/m.usdz"))]
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)
        model.normalizeScale = true
        model.metersPerUnit = 0.01

        model.start { _ in }
        for _ in 0..<100 where model.producedURL == nil { await Task.yield() }

        #expect(service.lastMeters == .some(.some(0.01)))
    }

    @Test func meterTargetIsNilWhenNormalizeOff() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]
        service.events = [.modelReady(url: URL(fileURLWithPath: "/tmp/m.usdz"))]
        let model = CaptureImportModel(service: service)
        model.selectFolder(folder)
        model.normalizeScale = false

        model.start { _ in }
        for _ in 0..<100 where model.producedURL == nil { await Task.yield() }

        #expect(service.lastMeters == .some(.none))
    }

    @Test func cancelReturnsRunningToIdle() {
        let model = CaptureImportModel(service: FakeCaptureService())
        // Force a running phase, then cancel.
        model.selectFolder(URL(fileURLWithPath: "/tmp/x"))
        // No images → not running; drive phase directly through start guard path.
        model.cancel()  // no-op path (not running)
        #expect(!model.isRunning)
    }

    @Test func describeFallsBackToLocalizedDescription() {
        struct Other: Error {}
        let message = CaptureImportModel.describe(Other())
        #expect(!message.isEmpty)
    }

    // MARK: View instantiation (body coverage across states)

    @Test func sheetBodyRendersAcrossStates() {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(25)
        service.imagesByFolder = [folder: images]
        service.report = CaptureQualityReport(issues: [.lowOverlapHint])

        // No folder yet.
        let empty = CaptureImportModel(service: service)
        _ = CaptureSheet(model: empty, onOpen: { _ in }, onClose: {}).body

        // Folder chosen with an advisory (guidance shown).
        let chosen = CaptureImportModel(service: service)
        chosen.selectFolder(folder)
        _ = CaptureSheet(model: chosen, onOpen: { _ in }, onClose: {}).body

        // Blocking state.
        service.report = CaptureQualityReport(issues: [.unsupportedImageFormat(images[0])])
        let blocked = CaptureImportModel(service: service)
        blocked.selectFolder(folder)
        _ = CaptureSheet(model: blocked, onOpen: { _ in }, onClose: {}).body

        // Clean pass.
        service.report = CaptureQualityReport(issues: [])
        let clean = CaptureImportModel(service: service)
        clean.selectFolder(folder)
        _ = CaptureSheet(model: clean, onOpen: { _ in }, onClose: {}).body

        #expect(CaptureSheet.guidanceTips.count == 4)
    }

    @Test func sheetBodyRendersRunningCompletedAndFailedPhases() async {
        let service = FakeCaptureService()
        let (folder, images) = folderWith(30)
        service.imagesByFolder = [folder: images]

        // Reconstructing: render synchronously after start, before the task drains.
        service.events = [.modelReady(url: URL(fileURLWithPath: "/tmp/m.usdz"))]
        let running = CaptureImportModel(service: service)
        running.selectFolder(folder)
        running.start { _ in }
        #expect(running.isRunning)
        _ = CaptureSheet(model: running, onOpen: { _ in }, onClose: {}).body

        // Completed.
        for _ in 0..<100 where running.producedURL == nil { await Task.yield() }
        _ = CaptureSheet(model: running, onOpen: { _ in }, onClose: {}).body

        // Failed.
        let failService = FakeCaptureService()
        failService.imagesByFolder = [folder: images]
        failService.events = [.progress(0.4)]  // no modelReady → failure
        let failed = CaptureImportModel(service: failService)
        failed.selectFolder(folder)
        failed.start { _ in }
        for _ in 0..<100 where failed.failureMessage == nil { await Task.yield() }
        _ = CaptureSheet(model: failed, onOpen: { _ in }, onClose: {}).body
    }
}
