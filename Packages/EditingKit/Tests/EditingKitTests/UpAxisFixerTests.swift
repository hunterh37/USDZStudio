import Testing
import USDCore
@testable import EditingKit

@Suite("UpAxisFixer")
struct UpAxisFixerTests {

    private func stage(upAxis: UpAxis, rootTransform: TRS? = nil) -> InMemoryStage {
        var attrs: [Attribute] = []
        if let rootTransform {
            attrs.append(Attribute(name: transformAttributeName, value: .matrix4(rootTransform.toMatrix())))
        }
        let root = Prim(path: PrimPath("/Model")!, typeName: "Xform", attributes: attrs)
        return InMemoryStage(StageSnapshot(
            metadata: StageMetadata(upAxis: upAxis, defaultPrim: "Model"),
            rootPrims: [root]))
    }

    @Test func noCommandWhenAlreadyYUp() {
        #expect(UpAxisFixer.command(for: stage(upAxis: .y)) == nil)
    }

    @Test func flipsMetadataToYUp() throws {
        let s = stage(upAxis: .z)
        let command = try #require(UpAxisFixer.command(for: s))
        #expect(command.label == "Fix Up Axis")
        try command.execute(on: s)
        #expect(s.metadata.upAxis == .y)
    }

    @Test func reorientsUntransformedRootByMinus90AboutX() throws {
        let s = stage(upAxis: .z, rootTransform: nil)
        try #require(UpAxisFixer.command(for: s)).execute(on: s)
        let trs = s.transform(at: PrimPath("/Model")!)
        #expect(abs(trs.rotationEulerDegrees[0] - (-90)) < 1e-6)
    }

    @Test func mapsOldUpDirectionOntoNewUp() throws {
        // A point sitting on the old up axis (+Z) must land on the new up (+Y)
        // once the reorientation is baked in — the invariant that keeps the
        // model standing upright after the metadata flip.
        let s = stage(upAxis: .z, rootTransform: nil)
        try #require(UpAxisFixer.command(for: s)).execute(on: s)
        let m = s.transform(at: PrimPath("/Model")!).toMatrix()
        // Row-vector transform of the local +Z basis: row 2 of the matrix.
        let mappedZ = [m[8], m[9], m[10]]
        #expect(abs(mappedZ[0]) < 1e-6)
        #expect(abs(mappedZ[1] - 1) < 1e-6)   // +Z → +Y
        #expect(abs(mappedZ[2]) < 1e-6)
    }

    @Test func composesWithAnExistingRootTransform() throws {
        // A root that already carries a translation keeps it; the reorientation
        // composes in world space rather than clobbering the transform.
        let s = stage(upAxis: .z, rootTransform: TRS(translation: [5, 0, 0]))
        try #require(UpAxisFixer.command(for: s)).execute(on: s)
        let trs = s.transform(at: PrimPath("/Model")!)
        #expect(abs(trs.translation[0] - 5) < 1e-6)
        #expect(abs(trs.rotationEulerDegrees[0] - (-90)) < 1e-6)
    }

    @Test func undoRestoresMetadataAndTransform() throws {
        let s = stage(upAxis: .z, rootTransform: nil)
        let command = try #require(UpAxisFixer.command(for: s))
        try command.execute(on: s)
        try command.undo(on: s)
        #expect(s.metadata.upAxis == .z)
        let trs = s.transform(at: PrimPath("/Model")!)
        #expect(abs(trs.rotationEulerDegrees[0]) < 1e-6)
    }
}
