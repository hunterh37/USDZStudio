import Testing
@testable import SculptKit

@Suite struct SpecModelTests {

    // MARK: - ShapeKind

    @Test func shapeKindAuthorsGeometry() {
        #expect(ShapeKind.group.authorsGeometry == false)
        #expect(ShapeKind.primitive(.box).authorsGeometry == true)
        #expect(ShapeKind.library(entryID: "prim.cube").authorsGeometry == true)
        #expect(ShapeKind.Primitive.allCases.count == 5)
    }

    // MARK: - ComponentNode / spec derivations

    static func sampleSpec() -> ObjectSculptSpec {
        let leaf = ComponentNode(
            name: "Lid", shape: .primitive(.cylinder), materialID: "wood")
        let body = ComponentNode(
            name: "Body", shape: .primitive(.cylinder),
            materialID: "wood", children: [leaf])
        let root = ComponentNode(name: "Barrel", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Barrel", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "wood", baseColor: [0.4, 0.2, 0.1])])
    }

    @Test func specDerivations() {
        let spec = Self.sampleSpec()
        #expect(spec.componentCount == 3)
        #expect(spec.allNodes.map(\.name) == ["Barrel", "Body", "Lid"])
        #expect(spec.materialIDs == ["wood"])
        // Barrel is a group (not geometry); Body has a child; only Lid is a geometry leaf.
        #expect(spec.geometryLeaves.map(\.name) == ["Lid"])
        #expect(spec.root.flattened.count == 3)
        #expect(spec.root.id == "Barrel")   // Identifiable id == name
    }

    @Test func specRoundTrips() throws {
        var spec = Self.sampleSpec()
        spec.sockets = [Socket(name: "top", translation: [0, 1, 0])]
        spec.detailInventory.upsert(DetailItem(id: "d1", description: "wood grain", kind: .linework, mappedTo: "wood"))
        spec.materials[0].emissive = [0, 0, 0]
        spec.reviewHistory = [PassReview(pass: .blockout, decision: .continue, score: 0.9,
                                         renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png", note: "ok")]
        spec.root.children[0].repetition = RepetitionSystem(name: "hoop", count: 3, step: [0, 0.3, 0])
        let data = try spec.encoded()
        let decoded = try ObjectSculptSpec.decoded(from: data)
        #expect(decoded == spec)
    }

    // MARK: - DetailInventory

    @Test func detailInventoryMapping() {
        var inv = DetailInventory()
        inv.upsert(DetailItem(id: "a", description: "bevel", kind: .bevel))
        inv.upsert(DetailItem(id: "b", description: "gloss", kind: .gloss))
        #expect(inv.isFullyMapped == false)
        #expect(inv.unmapped.count == 2)
        #expect(inv.mapped.isEmpty)

        // upsert existing id replaces.
        inv.upsert(DetailItem(id: "a", description: "big bevel", kind: .bevel))
        #expect(inv.items.count == 2)
        #expect(inv.items.first?.description == "big bevel")

        #expect(inv.map(id: "a", to: "Body") == true)
        #expect(inv.map(id: "missing", to: "X") == false)
        #expect(inv.items.first(where: { $0.id == "a" })?.isMapped == true)

        inv.map(id: "b", to: "mat")
        #expect(inv.isFullyMapped)
        #expect(inv.mapped.count == 2)
        #expect(DetailKind.allCases.count == 8)
    }

    // MARK: - SculptPass

    @Test func passOrderingAndNavigation() {
        #expect(SculptPass.allCases.count == 8)
        #expect(SculptPass.blockout.index == 0)
        #expect(SculptPass.blockout.next == .structural)
        #expect(SculptPass.optimization.next == nil)
        #expect(SculptPass.blockout < SculptPass.material)
        for pass in SculptPass.allCases {
            #expect(!pass.responsibility.isEmpty)
        }
    }

    @Test func passDecisionEquatable() {
        #expect(PassDecision.continue == PassDecision.continue)
        #expect(PassDecision.stop != PassDecision.continue)
    }
}
