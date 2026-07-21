import Testing
import Foundation
import USDCore
import ViewportKit
@testable import SessionKit

/// Value-model coverage: CameraState, ViewState, SessionState, DocumentSession —
/// construction, Codable round-trips, and lenient decoding.
struct ModelTests {

    // MARK: CameraState

    @Test func cameraStateRoundTripsThroughPose() {
        let pose = ViewportCameraPose(target: SIMD3(1, 2, 3), distance: 5,
                                      azimuth: 0.4, elevation: 0.6)
        let state = CameraState(pose: pose)
        #expect(state.target == [1, 2, 3])
        #expect(state.pose == pose)
    }

    @Test func cameraStateMalformedTargetDegradesToOrigin() {
        let state = CameraState(target: [1, 2], distance: 1, azimuth: 0, elevation: 0)
        #expect(state.pose.target == .zero)
    }

    @Test func cameraStateIsCodable() throws {
        let state = CameraState(target: [0, 1, 0], distance: 2, azimuth: 1, elevation: 0.2)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CameraState.self, from: data)
        #expect(decoded == state)
    }

    // MARK: ViewState

    @Test func viewStateFullRoundTrip() throws {
        let state = ViewState(
            selectionPaths: ["/A", "/B"],
            primarySelectionPath: "/A",
            collapsedPaths: ["/C"],
            gizmoMode: "rotate",
            gizmoOrientation: "local",
            gizmoPivotMode: "median",
            isolationRoots: ["/A"],
            panelVisibility: ["diff": true, "validation": false],
            camera: CameraState(target: [0, 0, 0], distance: 3, azimuth: 0, elevation: 0),
            environment: EnvironmentSettings(exposureEV: 1),
            playbackPosition: 2.5)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ViewState.self, from: data)
        #expect(decoded == state)
    }

    @Test func viewStateDefaultsWhenEmptyJSON() throws {
        let decoded = try JSONDecoder().decode(ViewState.self, from: Data("{}".utf8))
        #expect(decoded == ViewState())
        #expect(decoded.selectionPaths.isEmpty)
        #expect(decoded.panelVisibility.isEmpty)
        #expect(decoded.camera == nil)
        #expect(decoded.environment == nil)
        #expect(decoded.playbackPosition == nil)
    }

    @Test func viewStatePartialJSONFillsMissingFields() throws {
        let json = #"{"selectionPaths":["/Only"],"gizmoMode":"scale"}"#
        let decoded = try JSONDecoder().decode(ViewState.self, from: Data(json.utf8))
        #expect(decoded.selectionPaths == ["/Only"])
        #expect(decoded.gizmoMode == "scale")
        #expect(decoded.collapsedPaths.isEmpty)
        #expect(decoded.primarySelectionPath == nil)
    }

    @Test func viewStateDefaultInitIsEmpty() {
        let state = ViewState()
        #expect(state.selectionPaths.isEmpty)
        #expect(state.isolationRoots.isEmpty)
        #expect(state.gizmoMode == nil)
    }

    // MARK: SessionState

    @Test func sessionStateDefaults() {
        let state = SessionState()
        #expect(state.schemaVersion == SessionState.currentSchemaVersion)
        #expect(state.documents.isEmpty)
        #expect(state.primaryDocument == nil)
    }

    @Test func sessionStateSingleDocumentConvenience() {
        let doc = DocumentSession(journalRelativePath: "journal.jsonl")
        let state = SessionState(document: doc)
        #expect(state.documents.count == 1)
        #expect(state.primaryDocument == doc)
    }

    @Test func sessionStateRoundTrip() throws {
        let doc = DocumentSession(
            source: SourceReference(bookmark: nil, path: "/tmp/x.usdz"),
            fingerprint: SourceFingerprint(size: 10, modified: Date(timeIntervalSince1970: 100)),
            journalRelativePath: "journal.jsonl",
            savedRevision: 3,
            embeddedSnapshot: nil,
            viewState: ViewState(selectionPaths: ["/A"]))
        let state = SessionState(document: doc)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(decoded == state)
    }

    // MARK: DocumentSession

    @Test func scratchSceneNeverReportsSourceChange() {
        let doc = DocumentSession(journalRelativePath: "j.jsonl")
        #expect(doc.sourceChangedOnDisk() == false)
    }

    @Test func nilFingerprintNeverReportsSourceChange() {
        let doc = DocumentSession(
            source: SourceReference(bookmark: nil, path: "/tmp/does-not-matter"),
            fingerprint: nil,
            journalRelativePath: "j.jsonl")
        #expect(doc.sourceChangedOnDisk() == false)
    }

    @Test func unresolvableSourceReportsNoChange() {
        // Both bookmark and path nil → resolve() is nil → the guard's false path.
        let doc = DocumentSession(
            source: SourceReference(bookmark: nil, path: nil),
            fingerprint: SourceFingerprint(size: 1, modified: .distantPast),
            journalRelativePath: "j.jsonl")
        #expect(doc.sourceChangedOnDisk() == false)
    }

    @Test func embeddedSnapshotSurvivesRoundTrip() throws {
        let snapshot = StageSnapshot()
        let doc = DocumentSession(journalRelativePath: "j.jsonl", embeddedSnapshot: snapshot)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(DocumentSession.self, from: data)
        #expect(decoded.embeddedSnapshot == snapshot)
    }
}
