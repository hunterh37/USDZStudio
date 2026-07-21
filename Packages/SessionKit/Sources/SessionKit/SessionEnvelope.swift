import Foundation

/// The versioned, serialized envelope written alongside a session's write-ahead
/// log (as `session.json` in the `EditingKit.SessionStore` session directory).
///
/// `schemaVersion` is the forward-compatibility hinge: `EnvelopeStore` discards
/// an envelope whose version it does not recognise (newer than this build, or a
/// version whose migration is not implemented) and reports no envelope, so a
/// future on-disk format can never wedge an older build's launch. Value
/// migrations for older versions slot into `EnvelopeStore.decode(_:)`.
public struct SessionEnvelope: Equatable, Codable, Sendable {
    /// The schema version this build writes and understands.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var document: DocumentSession

    public init(
        document: DocumentSession,
        schemaVersion: Int = SessionEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.document = document
    }

    /// Whether this build understands the envelope's schema version.
    public var isCompatible: Bool {
        schemaVersion == SessionEnvelope.currentSchemaVersion
    }
}

/// Reads and writes a session's ``SessionEnvelope`` (`session.json`) inside its
/// WAL directory. Injected so the app writes real files while tests use the
/// in-memory backend — mirroring the `EditingKit.SessionStore` `FileManager`
/// injection and the camera-bookmark/settings persistence pattern.
public protocol EnvelopeStore: Sendable {
    /// Persists `envelope` for the session in `directory` (atomically for the
    /// file backend).
    func write(_ envelope: SessionEnvelope, to directory: URL) throws
    /// Reads the envelope for the session in `directory`, or `nil` when it is
    /// absent, unreadable, corrupt, or of an incompatible schema version — every
    /// failure degrades to "no envelope", never an error that blocks launch.
    func read(from directory: URL) -> SessionEnvelope?
}

/// File-backed envelope store: one `session.json` per session directory, written
/// atomically (temp file + replace) so a crash mid-write leaves the prior good
/// file intact.
public final class FileEnvelopeStore: EnvelopeStore, @unchecked Sendable {
    public static let fileName = "session.json"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public func write(_ envelope: SessionEnvelope, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(envelope)
        let tempURL = directory.appendingPathComponent("\(Self.fileName).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        let target = directory.appendingPathComponent(Self.fileName)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
    }

    public func read(from directory: URL) -> SessionEnvelope? {
        let url = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(SessionEnvelope.self, from: data),
              envelope.isCompatible
        else { return nil }
        return envelope
    }
}

/// RAM-only envelope store for tests, keyed by the directory's normalized path
/// (so a trailing-slash difference between the write URL and the recovery-scan
/// URL, which are byte-unequal as `URL`s, still resolves to the same entry —
/// exactly what the file backend gets for free from the filesystem).
public final class InMemoryEnvelopeStore: EnvelopeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [String: SessionEnvelope] = [:]

    public init() {}

    private func key(_ directory: URL) -> String { directory.standardizedFileURL.path }

    public func write(_ envelope: SessionEnvelope, to directory: URL) throws {
        lock.withLock { envelopes[key(directory)] = envelope }
    }

    public func read(from directory: URL) -> SessionEnvelope? {
        lock.withLock {
            guard let envelope = envelopes[key(directory)], envelope.isCompatible else { return nil }
            return envelope
        }
    }
}
