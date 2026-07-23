import Foundation
import Testing
@testable import SculptKit

/// Tests for the #155–#161 issue sweep additions in SculptKit: shared
/// spec-named materials, component-name helpers for the spatial gate, and the
/// capability-handshake op list.
@Suite struct IssueSweepTests {

    static func spec(materials: [MaterialSpec], nodes: [ComponentNode]) -> ObjectSculptSpec {
        let root = ComponentNode(name: "Obj", shape: .group, children: nodes)
        return ObjectSculptSpec(name: "Obj", objectClass: .object, root: root, materials: materials)
    }

    // MARK: - Shared materials (#158)

    @Test func materialStepsMintOneMaterialPerSpecID() {
        let steel = MaterialSpec(id: "steel", baseColor: [0.5, 0.5, 0.5])
        let paint = MaterialSpec(id: "paint", baseColor: [0.8, 0.1, 0.1])
        let spec = Self.spec(materials: [steel, paint], nodes: [
            ComponentNode(name: "A", shape: .primitive(.box), materialID: "steel", attachment: .root),
            ComponentNode(name: "B", shape: .primitive(.box), materialID: "steel", attachment: .weld),
            ComponentNode(name: "C", shape: .primitive(.box), materialID: "paint", attachment: .weld),
        ])
        let steps = BuildPlanner.plan(for: spec, pass: .material)
        #expect(steps == [
            .createMaterial(targetPath: "/Obj/A", material: steel),
            .bindMaterial(targetPath: "/Obj/B", sourcePath: "/Obj/A"),
            .createMaterial(targetPath: "/Obj/C", material: paint),
        ])
    }

    @Test func repetitionCopiesBindTheSharedMaterial() {
        let steel = MaterialSpec(id: "steel", baseColor: [0.5, 0.5, 0.5])
        var base = ComponentNode(name: "A", shape: .primitive(.box), materialID: "steel", attachment: .root)
        base.repetition = RepetitionSystem(name: "row", kind: .linear, count: 2, step: [1, 0, 0])
        var second = ComponentNode(name: "B", shape: .primitive(.box), materialID: "steel", attachment: .weld)
        second.repetition = RepetitionSystem(name: "row", kind: .linear, count: 2, step: [1, 0, 0])
        let spec = Self.spec(materials: [steel], nodes: [base, second])
        let steps = BuildPlanner.plan(for: spec, pass: .material)
        // A mints; A's copy, B, and B's copy all bind back to A's material.
        #expect(steps == [
            .createMaterial(targetPath: "/Obj/A", material: steel),
            .bindMaterial(targetPath: "/Obj/A_row1", sourcePath: "/Obj/A"),
            .bindMaterial(targetPath: "/Obj/B", sourcePath: "/Obj/A"),
            .bindMaterial(targetPath: "/Obj/B_row1", sourcePath: "/Obj/A"),
        ])
    }

    // MARK: - Component-name helpers (#161)

    @Test func componentNameHelpersHonorAttachmentsAndCopies() {
        var wheel = ComponentNode(name: "Wheel", shape: .primitive(.cylinder), attachment: .weld)
        wheel.repetition = RepetitionSystem(name: "axle", kind: .linear, count: 2, step: [0, 0, 2])
        let spec = Self.spec(materials: [], nodes: [
            ComponentNode(name: "Body", shape: .primitive(.box), attachment: .root),
            wheel,
            ComponentNode(name: "Debris", shape: .primitive(.sphere), attachment: .free),
            ComponentNode(name: "Antenna", shape: .primitive(.cylinder)),
        ])
        #expect(spec.allComponentNames ==
            ["Obj", "Body", "Wheel", "Wheel_axle1", "Debris", "Antenna"])
        // free + unspecified attachments declare no contact; copies inherit.
        #expect(spec.declaredContactComponentNames == ["Body", "Wheel", "Wheel_axle1"])
    }

    // MARK: - Capability handshake (#155/#156)

    @Test func supportedKindNamesListsEveryRefinementKind() throws {
        #expect(MeshRefinement.supportedKindNames == ["inset", "subdivide", "taper", "bevel", "extrude"])
        // Each advertised name decodes — the handshake can't drift from the decoder.
        let samples = [
            #"{"kind":"inset","fraction":0.3,"depth":0.1}"#,
            #"{"kind":"subdivide","levels":1}"#,
            #"{"kind":"taper","axis":"y","scale":0.5}"#,
            #"{"kind":"bevel","width":0.05,"angleDegrees":30}"#,
            #"{"kind":"extrude","direction":"+z","distance":0.2}"#,
        ]
        for sample in samples {
            _ = try JSONDecoder().decode(MeshRefinement.self, from: Data(sample.utf8))
        }
    }

    // MARK: - Floor calibration unit coverage (#157/#145)

    @Test func calibratedFloorMatrix() {
        // Clean cutout (or unknown alpha, non-scene): base floors hold.
        #expect(PreSpecAssessment.similarityFloor(isCharacter: false, isScene: false, hasAlpha: true) == 0.5)
        #expect(PreSpecAssessment.similarityFloor(isCharacter: true, isScene: false, hasAlpha: true) == 0.55)
        #expect(PreSpecAssessment.similarityFloor(isCharacter: true, isScene: false, hasAlpha: nil) == 0.55)
        // Photographic signals (explicit no-alpha, or scene keywords): relaxed.
        #expect(PreSpecAssessment.similarityFloor(isCharacter: false, isScene: false, hasAlpha: false) == 0.3)
        #expect(PreSpecAssessment.similarityFloor(isCharacter: true, isScene: true, hasAlpha: nil) == 0.3)
    }

    @Test func assessSurfacesFloorNote() {
        let assessment = PreSpecAssessment.assess(hints: ["barrel"], width: 512, height: 512)
        #expect(assessment.notes.contains { $0.contains("similarityFloor 0.5") && $0.contains("interaction is exempt") })
    }
}
