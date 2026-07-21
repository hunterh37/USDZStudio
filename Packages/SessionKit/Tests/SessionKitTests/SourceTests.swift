import Testing
import Foundation
@testable import SessionKit

/// Coverage for SourceReference (bookmark/path resolution + display) and
/// SourceFingerprint (attribute reads + change detection), using real temp
/// files.
struct SourceTests {

    private func makeTempFile(bytes: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-\(UUID().uuidString).usdz")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: SourceReference

    @Test func capturesBookmarkAndPathAndResolvesViaBookmark() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = SourceReference(url: file)
        #expect(ref.bookmark != nil)
        #expect(ref.path == file.standardizedFileURL.path)
        let resolved = ref.resolve()
        #expect(resolved?.lastPathComponent == file.lastPathComponent)
    }

    @Test func invalidBookmarkFallsBackToPath() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = SourceReference(bookmark: Data([0x00, 0x01, 0x02]),
                                  path: file.standardizedFileURL.path)
        let resolved = ref.resolve()
        #expect(resolved?.lastPathComponent == file.lastPathComponent)
    }

    @Test func resolvesViaPathWhenNoBookmark() {
        let ref = SourceReference(bookmark: nil, path: "/tmp/thing.usdz")
        #expect(ref.resolve()?.path == "/tmp/thing.usdz")
    }

    @Test func resolvesToNilWhenEmpty() {
        let ref = SourceReference(bookmark: nil, path: nil)
        #expect(ref.resolve() == nil)
    }

    @Test func displayNameFromPathOrNil() {
        #expect(SourceReference(bookmark: nil, path: "/a/b/Robot.usdz").displayName == "Robot.usdz")
        #expect(SourceReference(bookmark: nil, path: nil).displayName == nil)
    }

    @Test func sourceReferenceIsCodable() throws {
        let ref = SourceReference(bookmark: Data([1, 2, 3]), path: "/x.usdz")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(SourceReference.self, from: data)
        #expect(decoded == ref)
    }

    // MARK: SourceFingerprint

    @Test func fingerprintMatchesUnchangedFile() throws {
        let file = try makeTempFile(bytes: 8)
        defer { try? FileManager.default.removeItem(at: file) }
        let fp = try SourceFingerprint.make(for: file)
        #expect(fp.size == 8)
        #expect(fp.matches(fileAt: file))
    }

    @Test func fingerprintDetectsSizeChange() throws {
        let file = try makeTempFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: file) }
        let fp = try SourceFingerprint.make(for: file)
        // Rewrite with a different size → fingerprint no longer matches.
        try Data(repeating: 0x42, count: 64).write(to: file)
        #expect(fp.matches(fileAt: file) == false)
    }

    @Test func fingerprintOfMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(throws: SessionError.self) {
            _ = try SourceFingerprint.make(for: missing)
        }
    }

    @Test func fingerprintMatchesFalseForMissingFile() {
        let fp = SourceFingerprint(size: 4, modified: .distantPast)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(fp.matches(fileAt: missing) == false)
    }

    @Test func fingerprintIsCodable() throws {
        let fp = SourceFingerprint(size: 42, modified: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(fp)
        let decoded = try JSONDecoder().decode(SourceFingerprint.self, from: data)
        #expect(decoded == fp)
    }
}
