import Testing
@testable import EditorUI

/// The reference-image panel's presentational model (specs/agent-live-editing.md
/// — "Reference panel"). Pure state; the panel view renders it.
@MainActor
@Suite struct ReferenceImageModelTests {

    @Test func startsEmpty() {
        let model = ReferenceImageModel()
        #expect(model.path == nil)
        #expect(model.caption == nil)
        #expect(model.hasReference == false)
    }

    @Test func setPopulatesAndFlagsPresence() {
        let model = ReferenceImageModel()
        model.set(path: "/tmp/robot.png", caption: "side view")
        #expect(model.path == "/tmp/robot.png")
        #expect(model.caption == "side view")
        #expect(model.hasReference)
    }

    @Test func clearingPathResetsPresence() {
        let model = ReferenceImageModel(path: "/tmp/a.png", caption: "x")
        #expect(model.hasReference)
        model.set(path: nil, caption: nil)
        #expect(model.hasReference == false)
        #expect(model.caption == nil)
    }

    @Test func initialValuesAreCarried() {
        let model = ReferenceImageModel(path: "/tmp/b.png", caption: "front")
        #expect(model.path == "/tmp/b.png")
        #expect(model.caption == "front")
        #expect(model.hasReference)
    }
}
