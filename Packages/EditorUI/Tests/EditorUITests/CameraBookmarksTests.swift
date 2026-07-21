import Testing
import Foundation
@testable import EditorUI
import ViewportKit

@MainActor
struct CameraBookmarksTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "camera.bookmarks.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private var samplePose: ViewportCameraPose {
        ViewportCameraPose(target: SIMD3(1, 2, 3), distance: 4, azimuth: 0.5, elevation: 0.2)
    }

    @Test func emptyByDefault() {
        #expect(CameraBookmarkStore(defaults: makeDefaults()).bookmarks.isEmpty)
    }

    @Test func addStoresAndPersists() {
        let defaults = makeDefaults()
        let store = CameraBookmarkStore(defaults: defaults)
        let saved = store.add(name: "Front", pose: samplePose)
        #expect(saved.name == "Front")
        #expect(store.bookmarks.count == 1)
        // A second store over the same defaults reloads it.
        #expect(CameraBookmarkStore(defaults: defaults).bookmarks.first?.name == "Front")
    }

    @Test func blankNameGetsPositionalDefault() {
        let store = CameraBookmarkStore(defaults: makeDefaults())
        #expect(store.add(name: "   ", pose: samplePose).name == "View 1")
        #expect(store.add(name: "", pose: samplePose).name == "View 2")
    }

    @Test func poseRoundTripsThroughBookmark() {
        let store = CameraBookmarkStore(defaults: makeDefaults())
        let saved = store.add(name: "P", pose: samplePose)
        let pose = saved.pose
        #expect(pose.target == SIMD3(1, 2, 3))
        #expect(pose.distance == 4)
        #expect(pose.azimuth == 0.5)
        #expect(pose.elevation == 0.2)
    }

    @Test func malformedTargetDegradesToOrigin() {
        var bookmark = CameraBookmark(name: "x", pose: samplePose)
        bookmark.target = [1, 2] // wrong arity
        #expect(bookmark.pose.target == .zero)
    }

    @Test func removeDeletesById() {
        let store = CameraBookmarkStore(defaults: makeDefaults())
        let a = store.add(name: "A", pose: samplePose)
        let b = store.add(name: "B", pose: samplePose)
        store.remove(a.id)
        #expect(store.bookmarks.map(\.id) == [b.id])
        store.remove(UUID()) // unknown id → no-op
        #expect(store.bookmarks.count == 1)
    }

    @Test func renameUpdatesAndIgnoresBlank() {
        let store = CameraBookmarkStore(defaults: makeDefaults())
        let a = store.add(name: "A", pose: samplePose)
        store.rename(a.id, to: "Renamed")
        #expect(store.bookmarks.first?.name == "Renamed")
        store.rename(a.id, to: "   ")
        #expect(store.bookmarks.first?.name == "Renamed")
        store.rename(UUID(), to: "X") // unknown id → no-op
        #expect(store.bookmarks.first?.name == "Renamed")
    }

    @Test func poseFromCameraCaptureRoundTrips() {
        var camera = OrbitCamera()
        camera.target = SIMD3(5, 6, 7)
        camera.distance = 9
        camera.azimuth = 1.1
        camera.elevation = 0.4
        let pose = ViewportCameraPose(camera: camera)
        #expect(pose.target == SIMD3(5, 6, 7))
        #expect(pose.distance == 9)
        #expect(pose.azimuth == 1.1)
        #expect(pose.elevation == 0.4)
    }

    @Test func loadDegradesOnCorruptData() {
        let defaults = makeDefaults()
        defaults.set(Data([9, 9, 9]), forKey: CameraBookmarkStore.storageKey)
        #expect(CameraBookmarkStore(defaults: defaults).bookmarks.isEmpty)
    }
}
