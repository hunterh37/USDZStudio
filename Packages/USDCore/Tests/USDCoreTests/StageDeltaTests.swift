import Testing
@testable import USDCore

/// Full-coverage exercise of `StageDelta` — the editor-wide, file-oriented
/// stage comparison. Every facet flag, attribute-change kind, metadata field,
/// and render branch is asserted.
@Suite("StageDelta")
struct StageDeltaTests {

    // MARK: - Fixtures

    private func attr(_ name: String, _ value: Double) -> Attribute {
        Attribute(name: name, value: .double(value))
    }

    private func prim(
        _ path: String,
        type: String = "Xform",
        active: Bool = true,
        visibility: Visibility = .inherited,
        attributes: [Attribute] = [],
        relationships: [Relationship] = [],
        metadata: [String: String] = [:],
        variantSets: [VariantSet] = [],
        children: [Prim] = []
    ) -> Prim {
        Prim(path: PrimPath(path)!, typeName: type, isActive: active,
             visibility: visibility, attributes: attributes, relationships: relationships,
             metadata: metadata, variantSets: variantSets, children: children)
    }

    private func stage(_ roots: [Prim], metadata: StageMetadata = StageMetadata()) -> StageSnapshot {
        StageSnapshot(metadata: metadata, rootPrims: roots)
    }

    // MARK: - Empty / identical

    @Test func identicalStagesProduceEmptyDelta() {
        let a = stage([prim("/Root", children: [prim("/Root/Child", attributes: [attr("x", 1)])])])
        let delta = StageDelta.compute(before: a, after: a)
        #expect(delta.isEmpty)
        #expect(delta.changeCount == 0)
        #expect(delta.summaryLines() == ["no differences"])
    }

    // MARK: - Added / removed

    @Test func detectsAddedAndRemovedPrims() {
        let before = stage([prim("/Root", children: [prim("/Root/Gone")])])
        let after = stage([prim("/Root", children: [prim("/Root/New")])])
        let delta = StageDelta.compute(before: before, after: after)
        #expect(delta.addedPrims == [PrimPath("/Root/New")!])
        #expect(delta.removedPrims == [PrimPath("/Root/Gone")!])
        #expect(delta.changedPrims.isEmpty)
        #expect(delta.changeCount == 2)
        #expect(!delta.isEmpty)
        let lines = delta.summaryLines()
        #expect(lines.contains("+ /Root/New"))
        #expect(lines.contains("- /Root/Gone"))
    }

    // MARK: - Per-facet changes

    @Test func detectsTypeChange() {
        let delta = StageDelta.compute(
            before: stage([prim("/A", type: "Xform")]),
            after: stage([prim("/A", type: "Mesh")]))
        #expect(delta.changedPrims.count == 1)
        #expect(delta.changedPrims[0].typeChanged)
        #expect(delta.changedPrims[0].changedFacets == ["type"])
    }

    @Test func detectsActivationChange() {
        let delta = StageDelta.compute(
            before: stage([prim("/A", active: true)]),
            after: stage([prim("/A", active: false)]))
        #expect(delta.changedPrims[0].activationChanged)
        #expect(delta.changedPrims[0].changedFacets == ["active"])
    }

    @Test func detectsVisibilityChange() {
        let delta = StageDelta.compute(
            before: stage([prim("/A", visibility: .inherited)]),
            after: stage([prim("/A", visibility: .invisible)]))
        #expect(delta.changedPrims[0].visibilityChanged)
        #expect(delta.changedPrims[0].changedFacets == ["visibility"])
    }

    @Test func detectsRelationshipsChange() {
        let rel = Relationship(name: "material:binding", targets: [PrimPath("/Looks/M")!])
        let delta = StageDelta.compute(
            before: stage([prim("/A")]),
            after: stage([prim("/A", relationships: [rel])]))
        #expect(delta.changedPrims[0].relationshipsChanged)
        #expect(delta.changedPrims[0].changedFacets == ["relationships"])
    }

    @Test func detectsMetadataChange() {
        let delta = StageDelta.compute(
            before: stage([prim("/A")]),
            after: stage([prim("/A", metadata: ["kind": "component"])]))
        #expect(delta.changedPrims[0].metadataChanged)
        #expect(delta.changedPrims[0].changedFacets == ["metadata"])
    }

    @Test func detectsVariantSetsChange() {
        let vset = VariantSet(name: "color", variants: ["red", "blue"], selection: "red")
        let delta = StageDelta.compute(
            before: stage([prim("/A")]),
            after: stage([prim("/A", variantSets: [vset])]))
        #expect(delta.changedPrims[0].variantSetsChanged)
        #expect(delta.changedPrims[0].changedFacets == ["variants"])
    }

    @Test func combinesMultipleFacetsInDeterministicOrder() {
        let delta = StageDelta.compute(
            before: stage([prim("/A", type: "Xform", active: true, visibility: .inherited)]),
            after: stage([prim("/A", type: "Mesh", active: false, visibility: .invisible)]))
        #expect(delta.changedPrims[0].changedFacets == ["type", "active", "visibility"])
    }

    // MARK: - Attribute changes

    @Test func detectsAddedRemovedModifiedAttributes() {
        let before = stage([prim("/A", attributes: [attr("keep", 1), attr("gone", 2), attr("moved", 3)])])
        let after = stage([prim("/A", attributes: [attr("keep", 1), attr("moved", 9), attr("fresh", 4)])])
        let delta = StageDelta.compute(before: before, after: after)
        let change = delta.changedPrims[0]
        #expect(change.changedFacets == ["attributes(3)"])
        // Sorted by name: fresh(+), gone(-), moved(~)
        #expect(change.attributeChanges == [
            .init(name: "fresh", kind: .added),
            .init(name: "gone", kind: .removed),
            .init(name: "moved", kind: .modified),
        ])
    }

    @Test func unchangedAttributesProduceNoChange() {
        let a = stage([prim("/A", attributes: [attr("x", 1), attr("y", 2)])])
        #expect(StageDelta.compute(before: a, after: a).isEmpty)
    }

    // MARK: - Metadata fields

    @Test func detectsEveryMetadataFieldIndependently() {
        let base = StageMetadata()
        func changed(_ transform: (inout StageMetadata) -> Void) -> [String] {
            var m = base
            transform(&m)
            return StageDelta.compute(before: stage([], metadata: base),
                                      after: stage([], metadata: m)).changedMetadataFields
        }
        #expect(changed { $0.upAxis = .z } == ["upAxis"])
        #expect(changed { $0.metersPerUnit = 0.01 } == ["metersPerUnit"])
        #expect(changed { $0.defaultPrim = "Root" } == ["defaultPrim"])
        #expect(changed { $0.customLayerData = ["a": "b"] } == ["customLayerData"])
        #expect(changed { $0.timeCodesPerSecond = 24 } == ["timeCodesPerSecond"])
        #expect(changed { $0.startTimeCode = 0 } == ["startTimeCode"])
        #expect(changed { $0.endTimeCode = 10 } == ["endTimeCode"])
    }

    @Test func metadataChangeSurfacesInSummaryAndNotEmpty() {
        var after = StageMetadata()
        after.upAxis = .z
        let delta = StageDelta.compute(before: stage([]), after: stage([], metadata: after))
        #expect(!delta.isEmpty)
        #expect(delta.changeCount == 0)  // metadata-only: no prim-level changes
        #expect(delta.summaryLines().contains("~ <stage metadata> [upAxis]"))
    }

    // MARK: - Summary rendering of attribute rows

    @Test func summaryRendersAttributeSymbols() {
        let before = stage([prim("/A", attributes: [attr("gone", 1), attr("moved", 2)])])
        let after = stage([prim("/A", attributes: [attr("moved", 9), attr("fresh", 3)])])
        let lines = StageDelta.compute(before: before, after: after).summaryLines()
        #expect(lines.contains("~ /A [attributes(3)]"))
        #expect(lines.contains("    + fresh"))
        #expect(lines.contains("    - gone"))
        #expect(lines.contains("    ~ moved"))
    }

    // MARK: - Ordering & default init

    @Test func changedPrimsSortedByPath() {
        let before = stage([prim("/A", type: "Xform"), prim("/B", type: "Xform"), prim("/C", type: "Xform")])
        let after = stage([prim("/A", type: "Mesh"), prim("/B", type: "Mesh"), prim("/C", type: "Mesh")])
        let paths = StageDelta.compute(before: before, after: after).changedPrims.map(\.path)
        #expect(paths == [PrimPath("/A")!, PrimPath("/B")!, PrimPath("/C")!])
    }

    @Test func defaultInitializedDeltaIsEmpty() {
        #expect(StageDelta().isEmpty)
        #expect(StageDelta().summaryLines() == ["no differences"])
    }

    @Test func attributeChangeComparableSortsByName() {
        let a = StageDelta.AttributeChange(name: "alpha", kind: .modified)
        let b = StageDelta.AttributeChange(name: "beta", kind: .added)
        #expect(a < b)
    }

    @Test func primChangeComparableSortsByPath() {
        let a = StageDelta.PrimChange(path: PrimPath("/A")!, typeChanged: true)
        let b = StageDelta.PrimChange(path: PrimPath("/B")!, typeChanged: true)
        #expect(a < b)
    }
}
