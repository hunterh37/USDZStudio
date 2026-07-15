import Testing
import USDCore
@testable import EditingKit

@Suite("ScaleFixer")
struct ScaleFixerTests {

    private func stage(metersPerUnit: Double, rootScale: [Double]? = nil) -> InMemoryStage {
        var attrs: [Attribute] = []
        if let rootScale {
            let trs = TRS(scale: rootScale)
            attrs.append(Attribute(name: transformAttributeName, value: .matrix4(trs.toMatrix())))
        }
        let root = Prim(path: PrimPath("/Model")!, typeName: "Xform", attributes: attrs)
        return InMemoryStage(StageSnapshot(
            metadata: StageMetadata(metersPerUnit: metersPerUnit, defaultPrim: "Model"),
            rootPrims: [root]))
    }

    @Test func noCommandWhenAlreadyAtTarget() {
        #expect(ScaleFixer.command(for: stage(metersPerUnit: 1.0)) == nil)
    }

    @Test func rejectsNonPositiveTarget() {
        #expect(ScaleFixer.command(for: stage(metersPerUnit: 0.01), targetMetersPerUnit: 0) == nil)
    }

    @Test func normalizesMetadataAndCompensatesScale() throws {
        // Centimetre stage: 0.01 m/unit. Fixing to 1.0 must shrink geometry 100×
        // so the rendered size is unchanged.
        let s = stage(metersPerUnit: 0.01, rootScale: [1, 1, 1])
        let command = try #require(ScaleFixer.command(for: s))
        #expect(command.label == "Fix Scale")
        try command.execute(on: s)

        #expect(s.metadata.metersPerUnit == 1.0)
        let scale = s.transform(at: PrimPath("/Model")!).scale
        for axis in scale { #expect(abs(axis - 0.01) < 1e-9) }
    }

    @Test func preservesRealWorldSize() throws {
        let s = stage(metersPerUnit: 0.01, rootScale: [2, 3, 4])
        let realBefore = s.transform(at: PrimPath("/Model")!).scale.map { $0 * s.metadata.metersPerUnit }
        try #require(ScaleFixer.command(for: s)).execute(on: s)
        let realAfter = s.transform(at: PrimPath("/Model")!).scale.map { $0 * s.metadata.metersPerUnit }
        for (a, b) in zip(realBefore, realAfter) { #expect(abs(a - b) < 1e-9) }
    }

    @Test func authorsScaleOnUntransformedRoot() throws {
        let s = stage(metersPerUnit: 100, rootScale: nil)  // no xformOp authored
        try #require(ScaleFixer.command(for: s)).execute(on: s)
        let scale = s.transform(at: PrimPath("/Model")!).scale
        for axis in scale { #expect(abs(axis - 100) < 1e-6) }  // factor 100/1
    }

    @Test func undoRestoresMetadataAndTransform() throws {
        let s = stage(metersPerUnit: 0.01, rootScale: [1, 1, 1])
        let command = try #require(ScaleFixer.command(for: s))
        try command.execute(on: s)
        try command.undo(on: s)

        #expect(s.metadata.metersPerUnit == 0.01)
        let scale = s.transform(at: PrimPath("/Model")!).scale
        for axis in scale { #expect(abs(axis - 1.0) < 1e-9) }
    }

    @Test func scalesEveryRootPrim() throws {
        let a = Prim(path: PrimPath("/A")!, typeName: "Xform")
        let b = Prim(path: PrimPath("/B")!, typeName: "Xform")
        let s = InMemoryStage(StageSnapshot(
            metadata: StageMetadata(metersPerUnit: 0.001), rootPrims: [a, b]))
        let command = try #require(ScaleFixer.command(for: s))
        // metadata edit + one transform edit per root.
        #expect(command.commands.count == 3)
        try command.execute(on: s)
        for path in [PrimPath("/A")!, PrimPath("/B")!] {
            #expect(abs(s.transform(at: path).scale[0] - 0.001) < 1e-9)
        }
    }
}
