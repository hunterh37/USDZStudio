import Testing
import Foundation
@testable import USDCore

/// Covers the UsdSkel-enabling serializer surface: stage time codes,
/// relationships, `uniform`, attribute metadata, time samples, and the
/// array value types (`token[]`, `float3[]`, `quatf[]`, `matrix4d[]`).
@Suite("Animation & skinning serialization")
struct AnimationSerializationTests {

    private func stage(_ prims: [Prim], _ metadata: StageMetadata = StageMetadata(defaultPrim: "Root")) -> StageSnapshot {
        StageSnapshot(metadata: metadata, rootPrims: prims)
    }

    // MARK: - Stage time codes

    @Test func emitsAnimationTimeCodes() {
        let usda = USDASerializer.serialize(stage([], StageMetadata(
            defaultPrim: "Root", timeCodesPerSecond: 24, startTimeCode: 0, endTimeCode: 48)))
        #expect(usda.contains("timeCodesPerSecond = 24"))
        #expect(usda.contains("startTimeCode = 0"))
        #expect(usda.contains("endTimeCode = 48"))
    }

    @Test func omitsTimeCodesWhenStatic() {
        let usda = USDASerializer.serialize(stage([]))
        #expect(!usda.contains("timeCodesPerSecond"))
        #expect(!usda.contains("startTimeCode"))
        #expect(!usda.contains("endTimeCode"))
    }

    @Test func metadataReportsAnimatedRange() {
        #expect(!StageMetadata().isAnimated)
        #expect(!StageMetadata(startTimeCode: 0).isAnimated)
        #expect(StageMetadata(startTimeCode: 0, endTimeCode: 10).isAnimated)
    }

    // MARK: - Relationships

    @Test func emitsSingleAndMultiTargetRelationships() {
        let prim = Prim(
            path: PrimPath("/Root/Mesh")!, typeName: "Mesh",
            relationships: [
                Relationship(name: "skel:skeleton", targets: [PrimPath("/Root/Skel")!]),
                Relationship(name: "skel:blendShapeTargets",
                             targets: [PrimPath("/Root/A")!, PrimPath("/Root/B")!], isUniform: true),
            ])
        let usda = USDASerializer.serialize(stage([prim]))
        #expect(usda.contains("rel skel:skeleton = </Root/Skel>"))
        // Relationships are uniform by definition; USD's text syntax has no
        // `uniform rel` form (it is a parse error), so even an `isUniform`
        // relationship serializes as a bare `rel`.
        #expect(usda.contains("rel skel:blendShapeTargets = [</Root/A>, </Root/B>]"))
        #expect(!usda.contains("uniform rel"))
    }

    // MARK: - uniform + attribute metadata

    @Test func emitsUniformPrefixAndAttributeMetadata() {
        let prim = Prim(path: PrimPath("/Root/Skin")!, typeName: "Mesh", attributes: [
            Attribute(name: "primvars:skel:jointIndices",
                      value: .intArray([0, 1, 2, 3]),
                      metadata: ["elementSize": "4", "interpolation": "\"vertex\""]),
            Attribute(name: "joints", value: .tokenArray(["Hips", "Hips/Spine"]), isUniform: true),
        ])
        let usda = USDASerializer.serialize(stage([prim]))
        #expect(usda.contains("int[] primvars:skel:jointIndices = [0, 1, 2, 3] ("))
        #expect(usda.contains("elementSize = 4"))
        #expect(usda.contains("interpolation = \"vertex\""))
        #expect(usda.contains("uniform token[] joints = [\"Hips\", \"Hips/Spine\"]"))
    }

    // MARK: - Time samples

    @Test func emitsTimeSampledAttribute() {
        let attribute = Attribute(
            name: "translations",
            value: .float3Array([]),  // type carrier
            timeSamples: [
                TimeSample(time: 0, value: .float3Array([0, 0, 0, 1, 0, 0])),
                TimeSample(time: 24, value: .float3Array([0, 1, 0, 1, 1, 0])),
            ])
        #expect(attribute.isAnimated)
        let prim = Prim(path: PrimPath("/Root/Anim")!, typeName: "SkelAnimation", attributes: [attribute])
        let usda = USDASerializer.serialize(stage([prim]))
        #expect(usda.contains("float3[] translations.timeSamples = {"))
        #expect(usda.contains("0: [(0, 0, 0), (1, 0, 0)],"))
        #expect(usda.contains("24: [(0, 1, 0), (1, 1, 0)],"))
    }

    @Test func staticAttributeHasNoTimeSamplesBlock() {
        #expect(!Attribute(name: "x", value: .double(1)).isAnimated)
        #expect(!Attribute(name: "x", value: .double(1), timeSamples: []).isAnimated)
    }

    // MARK: - Array value types

    @Test func serializesQuatAndMatrixArrays() {
        let prim = Prim(path: PrimPath("/Root/Skel")!, typeName: "Skeleton", attributes: [
            Attribute(name: "rotations", value: .quatfArray([1, 0, 0, 0, 0.7, 0.7, 0, 0]), isUniform: true),
            Attribute(name: "bindTransforms", value: .matrix4dArray(
                (0..<16).map(Double.init) + (0..<16).map(Double.init)), isUniform: true),
        ])
        let usda = USDASerializer.serialize(stage([prim]))
        #expect(usda.contains("uniform quatf[] rotations = [(1, 0, 0, 0), (0.7, 0.7, 0, 0)]"))
        #expect(usda.contains("uniform matrix4d[] bindTransforms = [( (0, 1, 2, 3), (4, 5, 6, 7),"))
        #expect(AttributeValue.quatfArray([]).typeLabel == "quatf[]")
        #expect(AttributeValue.matrix4dArray([]).typeLabel == "matrix4d[]")
        #expect(AttributeValue.float3Array([]).typeLabel == "float3[]")
        #expect(AttributeValue.tokenArray([]).typeLabel == "token[]")
    }

    @Test func malformedArrayBecomesOmittedComment() {
        // float3[] needs a multiple of 3; quatf[] a multiple of 4.
        let prim = Prim(path: PrimPath("/Root/Bad")!, typeName: "Mesh", attributes: [
            Attribute(name: "translations", value: .float3Array([1, 2])),
            Attribute(name: "rotations", value: .quatfArray([1, 2, 3])),
            Attribute(name: "bind", value: .matrix4dArray([1, 2, 3])),
        ])
        let usda = USDASerializer.serialize(stage([prim]))
        #expect(usda.contains("# unsupported attribute \"translations\" (float3[]) omitted"))
        #expect(usda.contains("# unsupported attribute \"rotations\" (quatf[]) omitted"))
        #expect(usda.contains("# unsupported attribute \"bind\" (matrix4d[]) omitted"))
    }

    @Test func newArrayValuesAreEditable() {
        #expect(AttributeValue.tokenArray([]).isEditable)
        #expect(AttributeValue.float3Array([]).isEditable)
        #expect(AttributeValue.quatfArray([]).isEditable)
        #expect(AttributeValue.matrix4dArray([]).isEditable)
    }
}
