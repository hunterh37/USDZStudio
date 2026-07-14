import Testing
import Foundation
@testable import USDCore

/// Shared fixture: a small car stage exercising hierarchy, attributes,
/// visibility, activation, and variants.
enum Fixtures {
    static func carStage() -> StageSnapshot {
        let frontLeft = Prim(
            path: PrimPath("/Car/Wheels/FrontLeft")!,
            typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .doubleArray([0, 1, 2])),
                Attribute(name: "xformOp:translate", value: .vector([0.5, 0, 1.2])),
            ])
        let frontRight = Prim(
            path: PrimPath("/Car/Wheels/FrontRight")!,
            typeName: "Mesh",
            visibility: .invisible)
        let wheels = Prim(
            path: PrimPath("/Car/Wheels")!,
            typeName: "Xform",
            children: [frontLeft, frontRight])
        let brokenPart = Prim(
            path: PrimPath("/Car/Antenna")!,
            typeName: "Mesh",
            isActive: false)
        let car = Prim(
            path: PrimPath("/Car")!,
            typeName: "Xform",
            metadata: ["kind": "assembly"],
            variantSets: [VariantSet(name: "color", variants: ["red", "blue"], selection: "red")],
            children: [wheels, brokenPart])
        return StageSnapshot(
            sourceURL: URL(fileURLWithPath: "/tmp/car.usdz"),
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 0.01, defaultPrim: "Car"),
            rootPrims: [car])
    }
}

@Suite("Prim")
struct PrimTests {

    let stage = Fixtures.carStage()

    @Test func nameComesFromPath() {
        #expect(stage.rootPrims[0].name == "Car")
    }

    @Test func flattenedIsDepthFirst() {
        let names = stage.rootPrims[0].flattened().map(\.name)
        #expect(names == ["Car", "Wheels", "FrontLeft", "FrontRight", "Antenna"])
    }

    @Test func primAtPathFindsDeepDescendant() {
        let target = PrimPath("/Car/Wheels/FrontLeft")!
        #expect(stage.rootPrims[0].prim(at: target)?.typeName == "Mesh")
    }

    @Test func primAtPathReturnsSelf() {
        let car = stage.rootPrims[0]
        #expect(car.prim(at: car.path) == car)
    }

    @Test func primAtPathMissesNonDescendants() {
        let car = stage.rootPrims[0]
        #expect(car.prim(at: PrimPath("/Boat")!) == nil)
        #expect(car.prim(at: PrimPath("/Car/Doors")!) == nil)
        #expect(car.prim(at: .root) == nil)
    }

    @Test func attributeLookup() {
        let prim = stage.prim(at: PrimPath("/Car/Wheels/FrontLeft")!)!
        #expect(prim.attribute(named: "points")?.value == .doubleArray([0, 1, 2]))
        #expect(prim.attribute(named: "missing") == nil)
    }

    @Test func defaultsAreActiveInheritedEmpty() {
        let prim = Prim(path: PrimPath("/X")!)
        #expect(prim.isActive)
        #expect(prim.visibility == .inherited)
        #expect(prim.typeName.isEmpty)
        #expect(prim.attributes.isEmpty && prim.children.isEmpty && prim.metadata.isEmpty && prim.variantSets.isEmpty)
    }
}

@Suite("VariantSet")
struct VariantSetTests {

    @Test func selectionValidation() {
        #expect(VariantSet(name: "c", variants: ["red"], selection: "red").hasValidSelection)
        #expect(VariantSet(name: "c", variants: ["red"], selection: nil).hasValidSelection)
        #expect(!VariantSet(name: "c", variants: ["red"], selection: "green").hasValidSelection)
    }
}

@Suite("AttributeValue")
struct AttributeValueTests {

    @Test func typeLabels() {
        #expect(AttributeValue.bool(true).typeLabel == "bool")
        #expect(AttributeValue.int(1).typeLabel == "int")
        #expect(AttributeValue.double(1).typeLabel == "double")
        #expect(AttributeValue.string("s").typeLabel == "string")
        #expect(AttributeValue.token("t").typeLabel == "token")
        #expect(AttributeValue.asset("a.png").typeLabel == "asset")
        #expect(AttributeValue.vector([1, 2, 3]).typeLabel == "double3")
        #expect(AttributeValue.vector([1, 2]).typeLabel == "double2")
        #expect(AttributeValue.matrix4(Array(repeating: 0, count: 16)).typeLabel == "matrix4d")
        #expect(AttributeValue.intArray([1]).typeLabel == "int[]")
        #expect(AttributeValue.doubleArray([1]).typeLabel == "double[]")
        #expect(AttributeValue.stringArray(["x"]).typeLabel == "string[]")
        #expect(AttributeValue.unsupported(typeName: "matrix2d").typeLabel == "matrix2d")
    }

    @Test func editability() {
        #expect(AttributeValue.double(1).isEditable)
        #expect(!AttributeValue.unsupported(typeName: "weird").isEditable)
    }
}

@Suite("Stage protocol & snapshot")
struct StageTests {

    let stage = Fixtures.carStage()

    @Test func allPrimsTraversesEverything() {
        #expect(stage.allPrims().count == 5)
        #expect(stage.primCount == 5)
    }

    @Test func primAtPathAcrossRoots() {
        let two = StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/A")!),
            Prim(path: PrimPath("/B")!, children: [Prim(path: PrimPath("/B/C")!)]),
        ])
        #expect(two.prim(at: PrimPath("/B/C")!) != nil)
        #expect(two.prim(at: PrimPath("/A")!) != nil)
        #expect(two.prim(at: PrimPath("/Z")!) == nil)
    }

    @Test func primsNamedFindsAllMatches() {
        #expect(stage.prims(named: "FrontLeft").count == 1)
        #expect(stage.prims(named: "Nope").isEmpty)
    }

    @Test func emptySnapshotDefaults() {
        let empty = StageSnapshot()
        #expect(empty.sourceURL == nil)
        #expect(empty.rootPrims.isEmpty)
        #expect(empty.primCount == 0)
        #expect(empty.metadata == StageMetadata())
    }

    @Test func metadataDefaults() {
        let metadata = StageMetadata()
        #expect(metadata.upAxis == .y)
        #expect(metadata.metersPerUnit == 1.0)
        #expect(metadata.defaultPrim == nil)
        #expect(metadata.customLayerData.isEmpty)
    }

    @Test func upAxisRawValues() {
        #expect(UpAxis(rawValue: "Y") == .y)
        #expect(UpAxis(rawValue: "Z") == .z)
        #expect(UpAxis(rawValue: "X") == nil)
    }

    @Test func stageMutationEquality() {
        let a = StageMutation.setVisibility(path: PrimPath("/Car")!, visibility: .invisible)
        let b = StageMutation.setVisibility(path: PrimPath("/Car")!, visibility: .invisible)
        #expect(a == b)
        #expect(a != .removePrim(path: PrimPath("/Car")!))
    }
}
