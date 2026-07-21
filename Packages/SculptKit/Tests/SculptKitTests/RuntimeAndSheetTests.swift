import Foundation
import Testing
@testable import SculptKit

@Suite struct SuitabilityTests {

    @Test func viableWhenHintedAndLargeEnough() {
        let a = PreSpecAssessment.assess(hints: ["wooden barrel"], width: 512, height: 512)
        #expect(a.suitability.suitability == .viable)
        #expect(a.suitability.isViable)
        #expect(a.suitability.reasons.isEmpty)
    }

    @Test func rejectsTinyReference() {
        let a = PreSpecAssessment.assess(hints: ["barrel"], width: 32, height: 512)
        #expect(a.suitability.suitability == .rejected)
        #expect(!a.suitability.isViable)
        #expect(a.suitability.reasons.contains { $0.contains("too small") })
    }

    @Test func needsMoreInputWhenNoHints() {
        let a = PreSpecAssessment.assess(hints: [], width: 256, height: 256)
        #expect(a.suitability.suitability == .needsMoreInput)
        #expect(a.suitability.reasons.contains { $0.contains("no descriptive hints") })
    }

    @Test func needsMoreInputForSingleHintCharacter() {
        let a = PreSpecAssessment.assess(hints: ["character"], width: 256, height: 256)
        #expect(a.suitability.suitability == .needsMoreInput)
        #expect(a.suitability.reasons.contains { $0.contains("character references") })
    }

    @Test func suitabilityRoundTrips() throws {
        let a = PreSpecAssessment.assess(hints: ["robot", "glossy"], width: 512, height: 512)
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(PreSpecAssessment.self, from: data)
        #expect(back == a)
    }
}

@Suite struct RuntimeLayerTests {

    static func spec(sockets: [Socket] = [], colliders: [Collider] = [],
                     groups: [DestructionGroup] = []) -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box))
        let root = ComponentNode(name: "Root", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "R", objectClass: .object, root: root,
            sockets: sockets, colliders: colliders, destructionGroups: groups)
    }

    @Test func manifestDerivesFromSpec() throws {
        let s = Self.spec(
            sockets: [Socket(name: "grip", translation: [0, 1, 0])],
            colliders: [Collider(name: "hull", kind: .box, component: "Body")],
            groups: [DestructionGroup(name: "shatter", members: ["Body"])])
        let manifest = RuntimeManifest(spec: s)
        #expect(manifest.nodes == ["Root", "Body"])
        #expect(manifest.isActionable)
        let json = try manifest.json()
        #expect(json.contains("grip"))
        #expect(json.contains("hull"))
        #expect(json.contains("shatter"))
    }

    @Test func manifestNotActionableWhenBare() {
        #expect(!RuntimeManifest(spec: Self.spec()).isActionable)
        // A socket alone is enough; a collider alone is enough.
        #expect(RuntimeManifest(spec: Self.spec(sockets: [Socket(name: "s", translation: [0, 0, 0])])).isActionable)
        #expect(RuntimeManifest(spec: Self.spec(colliders: [Collider(name: "c", kind: .sphere, component: "Body")])).isActionable)
    }

    @Test func actionReadyGate() {
        #expect(!SpecValidator.actionReady(Self.spec()).isValid)
        let ready = Self.spec(colliders: [Collider(name: "c", kind: .capsule, component: "Body")])
        #expect(SpecValidator.actionReady(ready).isValid)
    }

    @Test func runtimeSchemaValidation() {
        // Unknown collider component.
        let badComp = Self.spec(colliders: [Collider(name: "c", kind: .box, component: "Ghost")])
        #expect(SpecValidator.validate(badComp).errors.contains { $0.message.contains("unknown component") })

        // Bad center/size arity.
        let badArity = Self.spec(colliders: [Collider(name: "c", kind: .box, component: "Body", center: [0, 0], size: [1, 1, 1])])
        #expect(SpecValidator.validate(badArity).errors.contains { $0.message.contains("[x, y, z]") })

        // Non-positive size.
        let badSize = Self.spec(colliders: [Collider(name: "c", kind: .box, component: "Body", size: [1, 0, 1])])
        #expect(SpecValidator.validate(badSize).errors.contains { $0.message.contains("size components must be positive") })

        // Empty destruction group + unknown member.
        let badGroups = Self.spec(groups: [
            DestructionGroup(name: "empty", members: []),
            DestructionGroup(name: "bad", members: ["Ghost"])])
        let msgs = SpecValidator.validate(badGroups).errors.map(\.message)
        #expect(msgs.contains { $0.contains("no members") })
        #expect(msgs.contains { $0.contains("unknown component 'Ghost'") })

        // A well-formed runtime layer is schema-valid.
        let good = Self.spec(
            sockets: [Socket(name: "g", translation: [0, 0, 0])],
            colliders: [Collider(name: "c", kind: .box, component: "Body")],
            groups: [DestructionGroup(name: "grp", members: ["Body"])])
        #expect(SpecValidator.validate(good).isValid)
    }

    @Test func runtimeSurvivesRoundTripAndLegacyDecode() throws {
        let s = Self.spec(
            sockets: [Socket(name: "g", translation: [0, 0, 0])],
            colliders: [Collider(name: "c", kind: .convexHull, component: "Body")])
        let back = try ObjectSculptSpec.decoded(from: s.encoded())
        #expect(back == s)

        // A legacy spec JSON with no runtime/material keys still decodes.
        let legacy = #"{"name":"L","objectClass":"object","root":{"name":"Root","shape":{"group":{}},"translation":[0,0,0],"rotationEulerDegrees":[0,0,0],"scale":[1,1,1],"width":1,"height":1,"depth":1,"radius":0.5,"segments":16,"children":[]}}"#
        let decoded = try ObjectSculptSpec.decoded(from: Data(legacy.utf8))
        #expect(decoded.colliders.isEmpty)
        #expect(decoded.materials.isEmpty)
        #expect(decoded.destructionGroups.isEmpty)
    }
}

@Suite struct RepetitionKindTests {

    static func node(_ rep: RepetitionSystem) -> ComponentNode {
        ComponentNode(name: "Bolt", shape: .primitive(.cylinder), translation: [0, 0, 0], repetition: rep)
    }

    @Test func linearIsDefault() {
        let copies = BuildPlanner.copies(for: Self.node(RepetitionSystem(name: "r", count: 3, step: [1, 0, 0])))
        #expect(copies.map(\.name) == ["Bolt_r1", "Bolt_r2"])
        #expect(copies[1].translation == [2, 0, 0])
    }

    @Test func radialRevolvesAroundAxis() {
        let copies = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .radial, count: 4, step: [1, 0, 0])))
        #expect(copies.count == 3)
        // Quarter turn around +Y: [1,0,0] → about [0,0,-1].
        #expect(abs(copies[0].translation[0]) < 1e-9)
        #expect(abs(copies[0].translation[2] - -1) < 1e-9)
    }

    @Test func radialFallsBackForDegenerateAxis() {
        // Zero-length axis normalizes to +Y; wrong-arity axis likewise.
        let copies = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .radial, count: 4, step: [1, 0, 0], axis: [0, 0, 0])))
        #expect(abs(copies[0].translation[2] - -1) < 1e-9)
        let copies2 = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .radial, count: 4, step: [1, 0, 0], axis: [1, 0])))
        #expect(copies2.count == 3)
    }

    @Test func gridLaysOutLattice() {
        let copies = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .grid, count: 4, step: [1, 1, 1], gridCounts: [2, 2, 1])))
        // 2×2×1 = 4 cells, minus the base cell = 3 copies.
        #expect(copies.count == 3)
        #expect(copies.map(\.name) == ["Bolt_r1", "Bolt_r2", "Bolt_r3"])
    }

    @Test func gridDefaultsWhenCountsMissing() {
        let copies = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .grid, count: 3, step: [1, 0, 0])))
        // Defaults to a single row of `count` → 2 extra copies.
        #expect(copies.count == 2)
        // Malformed gridCounts also fall back.
        let copies2 = BuildPlanner.copies(for: Self.node(
            RepetitionSystem(name: "r", kind: .grid, count: 3, step: [1, 0, 0], gridCounts: [0, 1, 1])))
        #expect(copies2.count == 2)
    }

    @Test func kindDecodeDefaultsToLinear() throws {
        // JSON without "kind" (legacy) decodes as linear.
        let legacy = #"{"name":"r","count":2,"step":[1,0,0]}"#
        let rep = try JSONDecoder().decode(RepetitionSystem.self, from: Data(legacy.utf8))
        #expect(rep.kind == .linear)
        // Round-trip of a radial rep preserves kind + axis.
        let radial = RepetitionSystem(name: "r", kind: .radial, count: 3, step: [1, 0, 0], axis: [0, 1, 0])
        let back = try JSONDecoder().decode(RepetitionSystem.self, from: JSONEncoder().encode(radial))
        #expect(back == radial)
    }

    @Test func interactionPassAuthorsRuntimeWhenActionable() {
        let body = ComponentNode(name: "Body", shape: .primitive(.box))
        let root = ComponentNode(name: "Root", shape: .group, children: [body])
        var spec = ObjectSculptSpec(
            name: "R", objectClass: .object, root: root,
            colliders: [Collider(name: "c", kind: .box, component: "Body")])
        let steps = BuildPlanner.plan(for: spec, pass: .interaction)
        #expect(steps.count == 1)
        if case .authorRuntime(let rootPath, let json) = steps[0] {
            #expect(rootPath == "/Root")
            #expect(json.contains("Body"))
        } else { Issue.record("expected authorRuntime step") }

        // No runtime data → interaction stays review-only.
        spec.colliders = []
        #expect(BuildPlanner.plan(for: spec, pass: .interaction).isEmpty)
    }
}

@Suite struct ComparisonSheetTests {

    @Test func svgPlacesBothImagesSideBySide() {
        let sheet = ComparisonSheet(pass: .blockout, referencePath: "/tmp/ref.png", renderPath: "/tmp/out.png", size: 256)
        let svg = sheet.svg()
        #expect(svg.contains("width=\"512\""))          // 2 × 256
        #expect(svg.contains("file:///tmp/ref.png"))
        #expect(svg.contains("file:///tmp/out.png"))
        #expect(svg.contains("Reference"))
        #expect(svg.contains("blockout"))
    }

    @Test func fileHrefEncodesAndPreservesExistingURLs() {
        #expect(ComparisonSheet.fileHref("/a b/c.png") == "file:///a%20b/c.png")
        #expect(ComparisonSheet.fileHref("file:///already.png") == "file:///already.png")
    }

    @Test func sizeIsClampedPositive() {
        #expect(ComparisonSheet(pass: .material, referencePath: "a", renderPath: "b", size: 0).size == 1)
    }
}
