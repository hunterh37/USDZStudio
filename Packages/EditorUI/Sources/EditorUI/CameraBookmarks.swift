import Foundation
import Observation
import ViewportKit

/// A named, persisted camera pose (ROADMAP Phase 5 — "Camera bookmarks").
/// Stores the four orbit-camera parameters plus a stable id so the list is
/// reorder- and rename-safe.
public struct CameraBookmark: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var target: [Double]
    public var distance: Double
    public var azimuth: Double
    public var elevation: Double

    public init(id: UUID = UUID(), name: String, pose: ViewportCameraPose) {
        self.id = id
        self.name = name
        self.target = [pose.target.x, pose.target.y, pose.target.z]
        self.distance = pose.distance
        self.azimuth = pose.azimuth
        self.elevation = pose.elevation
    }

    /// The stored parameters as a viewport pose. A malformed target (wrong
    /// arity, e.g. from hand-edited defaults) degrades to the origin rather
    /// than crashing.
    public var pose: ViewportCameraPose {
        let t = target.count == 3 ? SIMD3<Double>(target[0], target[1], target[2]) : .zero
        return ViewportCameraPose(target: t, distance: distance,
                                  azimuth: azimuth, elevation: elevation)
    }
}

/// Persisted collection of camera bookmarks for the current document window.
/// Backed by an injectable `UserDefaults` (ephemeral suite in tests), stored as
/// one JSON array so a single read/write covers the whole list.
@Observable
@MainActor
public final class CameraBookmarkStore {

    public static let storageKey = "editor.camera.bookmarks"

    @ObservationIgnored private let defaults: UserDefaults

    /// The bookmarks, most-recently-added last. Every mutation persists.
    public private(set) var bookmarks: [CameraBookmark]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bookmarks = Self.load(from: defaults)
    }

    /// Adds a bookmark capturing `pose` under `name`. A blank name falls back to
    /// a positional default ("View N"); the returned value is the stored record.
    @discardableResult
    public func add(name: String, pose: ViewportCameraPose) -> CameraBookmark {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "View \(bookmarks.count + 1)" : trimmed
        let bookmark = CameraBookmark(name: resolved, pose: pose)
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    /// Removes the bookmark with `id` (no-op if absent).
    public func remove(_ id: CameraBookmark.ID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    /// Renames the bookmark with `id`; a blank name is ignored so a bookmark can
    /// never become nameless.
    public func rename(_ id: CameraBookmark.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id })
        else { return }
        bookmarks[index].name = trimmed
        persist()
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [CameraBookmark] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CameraBookmark].self, from: data)
        else { return [] }
        return decoded
    }
}
