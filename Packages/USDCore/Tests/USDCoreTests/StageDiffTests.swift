import Testing
import Foundation
@testable import USDCore

@Suite("StageDiff")
struct StageDiffTests {

    // MARK: Helpers

    private func path(_ s: String) -> PrimPath { PrimPath(s)! }

    private func stage(metadata: StageMetadata = StageMetadata(), _ prims: [Prim]) -> StageSnapshot {
        StageSnapshot(metadata: metadata, rootPrims: prims)
    }

    // MARK: Identity

    @Test func identicalStagesProduceEmptyDiff() {
        let a = stage([Prim(path: path("/Root"), typeName: "Xform")])
        let diff = StageDiff.between(a, a)
        #expect(diff.isEmpty)
        #expect(diff.render() == "stages are identical")
    }

    // MARK: Metadata

    @Test func metadataFieldsDiff() {
        let before = StageMetadata(upAxis: .z, metersPerUnit: 0.01, defaultPrim: "A",
                                   customLayerData: ["k": "1", "drop": "x"],
                                   timeCodesPerSecond: 24, startTimeCode: 0, endTimeCode: 10)
        let after = StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: nil,
                                  customLayerData: ["k": "2", "new": "y"],
                                  timeCodesPerSecond: nil, startTimeCode: 1, endTimeCode: 10)
        let diff = StageDiff.between(stage(metadata: before, []), stage(metadata: after, []))
        let labels = diff.metadata.map(\.label)
        #expect(labels.contains("upAxis"))
        #expect(labels.contains("metersPerUnit"))
        #expect(labels.contains("defaultPrim"))
        #expect(labels.contains("timeCodesPerSecond"))
        #expect(labels.contains("startTimeCode"))
        #expect(!labels.contains("endTimeCode")) // unchanged
        #expect(labels.contains("customLayerData:k"))
        #expect(labels.contains("customLayerData:drop"))
        #expect(labels.contains("customLayerData:new"))
        // metersPerUnit integral renders without trailing .0
        let mpu = diff.metadata.first { $0.label == "metersPerUnit" }
        #expect(mpu?.after == "1")
        // dropped default prim shows ∅ on the after side
        let render = diff.render()
        #expect(render.contains("~ defaultPrim: A → ∅"))
        #expect(render.contains("Stage metadata ("))
    }

    // MARK: Prim add / remove

    @Test func addedAndRemovedPrims() {
        let before = stage([Prim(path: path("/Keep"), typeName: "Xform"),
                            Prim(path: path("/Gone"), typeName: "Mesh")])
        let after = stage([Prim(path: path("/Keep"), typeName: "Xform"),
                           Prim(path: path("/New"))]) // typeless -> "def"
        let diff = StageDiff.between(before, after)
        #expect(diff.addedPrims.map { $0.path.description } == ["/New"])
        #expect(diff.removedPrims.map { $0.path.description } == ["/Gone"])
        let render = diff.render()
        #expect(render.contains("Added prims (1):"))
        #expect(render.contains("+ /New (def)"))
        #expect(render.contains("Removed prims (1):"))
        #expect(render.contains("- /Gone (Mesh)"))
        #expect(!diff.isEmpty)
    }

    // MARK: Prim field changes

    @Test func scalarPrimFieldsChange() {
        let before = stage([Prim(path: path("/P"), typeName: "Xform",
                                 isActive: true, visibility: .inherited)])
        let after = stage([Prim(path: path("/P"), typeName: "Mesh",
                                isActive: false, visibility: .invisible)])
        let diff = StageDiff.between(before, after)
        let change = diff.changedPrims.first
        let labels = change?.changes.map(\.label) ?? []
        #expect(labels.contains("type"))
        #expect(labels.contains("active"))
        #expect(labels.contains("visibility"))
        let render = diff.render()
        #expect(render.contains("Changed prims (1):"))
        #expect(render.contains("/P"))
        #expect(render.contains("~ active: true → false"))
    }

    @Test func attributeRelationshipMetadataVariantChanges() {
        let before = stage([Prim(
            path: path("/P"),
            attributes: [Attribute(name: "keep", value: .int(1)),
                         Attribute(name: "gone", value: .double(2))],
            relationships: [Relationship(name: "material:binding", targets: [path("/Old")])],
            metadata: ["kind": "component"],
            variantSets: [VariantSet(name: "look", variants: ["a", "b"], selection: "a")])])
        let after = stage([Prim(
            path: path("/P"),
            attributes: [Attribute(name: "keep", value: .int(9)),
                         Attribute(name: "added", value: .string("hi"))],
            relationships: [Relationship(name: "material:binding", targets: [path("/New")])],
            metadata: ["kind": "group"],
            variantSets: [VariantSet(name: "look", variants: ["a", "b"], selection: "b")])])
        let diff = StageDiff.between(before, after)
        let labels = Set(diff.changedPrims.first?.changes.map(\.label) ?? [])
        #expect(labels.contains("attr:keep"))
        #expect(labels.contains("attr:gone"))
        #expect(labels.contains("attr:added"))
        #expect(labels.contains("rel:material:binding"))
        #expect(labels.contains("meta:kind"))
        #expect(labels.contains("variantSet:look"))
        // A removed attribute has ∅ on the after side.
        let render = diff.render()
        #expect(render.contains("attr:gone"))
        #expect(render.contains("→ ∅") || render.contains("∅ →"))
    }

    @Test func unchangedPrimIsNotListed() {
        let p = Prim(path: path("/Same"), typeName: "Xform",
                     attributes: [Attribute(name: "x", value: .int(1))])
        let diff = StageDiff.between(stage([p]), stage([p]))
        #expect(diff.changedPrims.isEmpty)
        #expect(diff.isEmpty)
    }

    // MARK: describe(_ value:) — every AttributeValue case

    @Test func describeCoversEveryValueCase() {
        #expect(StageDiff.describe(.bool(true)) == "true")
        #expect(StageDiff.describe(.int(3)) == "3")
        #expect(StageDiff.describe(.double(1.5)) == "1.5")
        #expect(StageDiff.describe(.string("s")) == "\"s\"")
        #expect(StageDiff.describe(.token("tok")) == "tok")
        #expect(StageDiff.describe(.asset("tex.png")) == "@tex.png@")
        #expect(StageDiff.describe(.vector([1, 2, 3])) == "(1, 2, 3)")
        #expect(StageDiff.describe(.matrix4([0, 1])) == "[0, 1]")
        #expect(StageDiff.describe(.intArray([1, 2])) == "[1, 2]")
        #expect(StageDiff.describe(.doubleArray([0.5])) == "[0.5]")
        #expect(StageDiff.describe(.stringArray(["a", "b"])) == "[\"a\", \"b\"]")
        #expect(StageDiff.describe(.tokenArray(["x", "y"])) == "[x, y]")
        #expect(StageDiff.describe(.float3Array([1, 2, 3])) == "[1, 2, 3]")
        #expect(StageDiff.describe(.quatfArray([1, 0, 0, 0])) == "[1, 0, 0, 0]")
        #expect(StageDiff.describe(.matrix4dArray([1])) == "[1]")
        #expect(StageDiff.describe(.unsupported(typeName: "Foo")) == "<Foo>")
    }

    // MARK: describe(_ attribute:) — flag / metadata / samples branches

    @Test func describeAttributeVariants() {
        let plain = Attribute(name: "a", value: .int(1))
        #expect(StageDiff.describe(plain) == "int = 1")

        let uniform = Attribute(name: "a", value: .int(1), isUniform: true)
        #expect(StageDiff.describe(uniform) == "uniform int = 1")

        let withMeta = Attribute(name: "a", value: .int(1),
                                 metadata: ["interpolation": "vertex", "elementSize": "3"])
        #expect(StageDiff.describe(withMeta).contains("(elementSize=3, interpolation=vertex)"))

        let animated = Attribute(name: "a", value: .double(0),
                                 timeSamples: [TimeSample(time: 0, value: .double(0)),
                                               TimeSample(time: 1, value: .double(5))])
        #expect(StageDiff.describe(animated).contains("{0: 0, 1: 5}"))
    }

    // MARK: describe(_ relationship:) and describe(_ variantSet:)

    @Test func describeRelationshipAndVariantSet() {
        let rel = Relationship(name: "r", targets: [path("/A"), path("/B")])
        #expect(StageDiff.describe(rel) == "[/A, /B]")
        let uniformRel = Relationship(name: "r", targets: [path("/A")], isUniform: true)
        #expect(StageDiff.describe(uniformRel) == "uniform [/A]")

        let selected = VariantSet(name: "v", variants: ["a", "b"], selection: "b")
        #expect(StageDiff.describe(selected) == "{a, b} = b")
        let cleared = VariantSet(name: "v", variants: ["a", "b"], selection: nil)
        #expect(StageDiff.describe(cleared) == "{a, b} = ∅")
    }

    // MARK: number formatting

    @Test func numberFormatting() {
        #expect(StageDiff.number(1.0) == "1")
        #expect(StageDiff.number(-3.0) == "-3")
        #expect(StageDiff.number(0.25) == "0.25")
        // Integral but too large to fit Int safely -> falls back to Double text.
        #expect(StageDiff.number(1e20) == String(1e20))
    }

    // MARK: JSON round-trips through Codable

    @Test func diffIsCodable() throws {
        let before = stage([Prim(path: path("/Gone"), typeName: "Mesh")])
        let after = stage([Prim(path: path("/New"), typeName: "Xform")])
        let diff = StageDiff.between(before, after)
        let data = try JSONEncoder().encode(diff)
        let decoded = try JSONDecoder().decode(StageDiff.self, from: data)
        #expect(decoded == diff)
    }
}
