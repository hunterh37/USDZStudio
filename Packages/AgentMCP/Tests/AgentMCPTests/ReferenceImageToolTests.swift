import Foundation
import Testing
import USDCore
@testable import AgentMCP

/// `set_reference_image` / `clear_reference_image`, the `usd://reference`
/// resource, the session hand-off callback, and the on-disk `reference.json`
/// record (specs/agent-live-editing.md — "Reference panel").
@Suite struct ReferenceImageToolTests {

    /// A real file on disk so the tool's existence check passes.
    private func imageFile() -> URL {
        let url = Fixtures.tempDirectory().appendingPathComponent("ref.png")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50]))
        return url
    }

    @Test func setStoresPathAndCaption() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let file = imageFile()
        let out = await callOK(server, "set_reference_image", .object([
            "path": .string(file.path), "caption": .string("robot side view"),
        ]))
        #expect(out["referenceImage"]["path"].stringValue == file.path)
        #expect(out["referenceImage"]["caption"].stringValue == "robot side view")
        #expect(session.referenceImage == ReferenceImage(path: file.path, caption: "robot side view"))
    }

    @Test func setWithoutCaptionYieldsNullCaption() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let out = await callOK(server, "set_reference_image", .object(["path": .string(imageFile().path)]))
        #expect(out["referenceImage"]["caption"].isNull)
        #expect(session.referenceImage?.caption == nil)
    }

    @Test func emptyCaptionIsTreatedAsAbsent() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "set_reference_image", .object([
            "path": .string(imageFile().path), "caption": .string(""),
        ]))
        #expect(session.referenceImage?.caption == nil)
    }

    @Test func missingPathIsCorrectableError() async {
        let server = Fixtures.server(session: Fixtures.session())
        let error = await callError(server, "set_reference_image")
        #expect(error.contains("missing 'path'"))
    }

    @Test func emptyPathIsCorrectableError() async {
        let server = Fixtures.server(session: Fixtures.session())
        let error = await callError(server, "set_reference_image", .object(["path": .string("")]))
        #expect(error.contains("missing 'path'"))
    }

    @Test func nonexistentFileIsCorrectableError() async {
        let server = Fixtures.server(session: Fixtures.session())
        let error = await callError(server, "set_reference_image",
                                    .object(["path": .string("/no/such/image.png")]))
        #expect(error.contains("no file at"))
    }

    @Test func clearResetsTheReference() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "set_reference_image", .object(["path": .string(imageFile().path)]))
        let out = await callOK(server, "clear_reference_image")
        #expect(out["cleared"].boolValue == true)
        #expect(session.referenceImage == nil)
    }

    @Test func changeCallbackFiresOnSetAndClear() async {
        let session = Fixtures.session()
        // Capture is serialized by the transport loop, so a plain box is safe.
        final class Box: @unchecked Sendable { var values: [ReferenceImage?] = [] }
        let box = Box()
        session.onReferenceImageChange = { box.values.append($0) }
        let server = Fixtures.server(session: session)
        let file = imageFile()
        _ = await callOK(server, "set_reference_image", .object(["path": .string(file.path)]))
        _ = await callOK(server, "clear_reference_image")
        #expect(box.values.count == 2)
        #expect(box.values[0] == ReferenceImage(path: file.path))
        #expect(box.values[1] == nil)
    }

    @Test func resourceReflectsCurrentReference() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Absent → the resource reads null.
        let before = await readResource(server, "usd://reference")
        #expect(before.isNull)

        let file = imageFile()
        _ = await callOK(server, "set_reference_image", .object([
            "path": .string(file.path), "caption": .string("front"),
        ]))
        let after = await readResource(server, "usd://reference")
        #expect(after["path"].stringValue == file.path)
        #expect(after["caption"].stringValue == "front")
    }

    // MARK: - reference.json hand-off record

    @Test func recordRoundTripsThroughDisk() throws {
        let url = Fixtures.tempDirectory().appendingPathComponent("nested/reference.json")
        let record = ReferenceImage(path: "/tmp/ref.png", caption: "hi")
        try record.write(to: url)   // also creates the nested directory
        #expect(ReferenceImage.read(from: url) == record)
        ReferenceImage.remove(at: url)
        #expect(ReferenceImage.read(from: url) == nil)
    }

    @Test func readMalformedRecordIsNil() throws {
        let url = Fixtures.tempDirectory().appendingPathComponent("reference.json")
        try Data("not json".utf8).write(to: url)
        #expect(ReferenceImage.read(from: url) == nil)
    }

    @Test func removeAbsentRecordIsNoOp() {
        let url = Fixtures.tempDirectory().appendingPathComponent("absent.json")
        ReferenceImage.remove(at: url)   // must not throw
        #expect(ReferenceImage.read(from: url) == nil)
    }
}

/// Read one MCP resource's provided JSON through the full `resources/read`
/// dispatch path (the resource body is JSON text we re-decode).
private func readResource(_ server: MCPServer, _ uri: String) async -> JSONValue {
    let request = JSONRPCRequest(
        id: .number(1), method: "resources/read", params: .object(["uri": .string(uri)]))
    let response = await server.handle(request: request)!
    let text = response["result"]["contents"].arrayValue?.first?["text"].stringValue ?? "null"
    return (try? JSONValue.parse(Data(text.utf8))) ?? .null
}
