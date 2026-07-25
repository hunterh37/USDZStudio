import Testing
@testable import ViewportKit

@Suite("FramePrimRequest")
struct FramePrimRequestTests {

    @Test("first request starts the token sequence at 1")
    func firstRequest() {
        let request = FramePrimRequest.next(after: nil, path: "/Root/Cube")
        #expect(request.path == "/Root/Cube")
        #expect(request.token == 1)
    }

    @Test("each successor bumps the token")
    func successorBumpsToken() {
        let first = FramePrimRequest.next(after: nil, path: "/Root/Cube")
        let second = FramePrimRequest.next(after: first, path: "/Root/Sphere")
        #expect(second.token == 2)
        #expect(second.path == "/Root/Sphere")
    }

    @Test("framing the same prim twice still produces a distinct request")
    func repeatedPathStillDistinct() {
        let first = FramePrimRequest.next(after: nil, path: "/Root/Cube")
        let second = FramePrimRequest.next(after: first, path: "/Root/Cube")
        #expect(first != second)
        #expect(second.shouldApply(lastApplied: first))
    }

    @Test("a nil path is a whole-model frame request")
    func nilPathAllowed() {
        let request = FramePrimRequest.next(after: nil, path: nil)
        #expect(request.path == nil)
        #expect(request.token == 1)
    }

    @Test("a fresh request applies when nothing was applied before")
    func appliesWithNoHistory() {
        #expect(FramePrimRequest(path: "/A", token: 1).shouldApply(lastApplied: nil))
    }

    @Test("re-delivery of an already-honoured request does not re-frame")
    func redeliveryIsIgnored() {
        let request = FramePrimRequest(path: "/A", token: 7)
        #expect(!request.shouldApply(lastApplied: request))
        // Same token, different path: still the same request generation.
        #expect(!FramePrimRequest(path: "/B", token: 7).shouldApply(lastApplied: request))
    }
}
