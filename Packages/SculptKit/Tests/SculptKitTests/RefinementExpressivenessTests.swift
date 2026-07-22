import Foundation
import Testing
@testable import SculptKit

/// Sculpt-accuracy P4 (#85): the declarative surface of the new expressiveness
/// ops — round-trip-safe coding (the acceptance criterion for spec persistence)
/// and the validator rules that keep degenerate parameters out of a build.
@Suite struct RefinementExpressivenessTests {

    static func roundTrip(_ op: MeshRefinement) throws -> MeshRefinement {
        let data = try JSONEncoder().encode([op])
        return try JSONDecoder().decode([MeshRefinement].self, from: data)[0]
    }

    @Test func newOpsRoundTripThroughCoding() throws {
        let ops: [MeshRefinement] = [
            .taper(axis: .y, scale: 0.4),
            .bevel(width: 0.05, angleDegrees: 45),
            .extrude(direction: .negZ, distance: -0.2),
        ]
        for op in ops {
            #expect(try Self.roundTrip(op) == op)
        }
        // bevel's angle threshold defaults to 30° when omitted (spec-authoring
        // ergonomics: "bevel the sharp edges" needs only a width).
        let bare = Data(#"{"kind":"bevel","width":0.1}"#.utf8)
        #expect(try JSONDecoder().decode(MeshRefinement.self, from: bare)
                == .bevel(width: 0.1, angleDegrees: 30))
    }

    @Test func directionUnitVectors() {
        let expected: [RefinementDirection: (Double, Double, Double)] = [
            .posX: (1, 0, 0), .negX: (-1, 0, 0),
            .posY: (0, 1, 0), .negY: (0, -1, 0),
            .posZ: (0, 0, 1), .negZ: (0, 0, -1),
        ]
        for (direction, unit) in expected {
            let v = direction.unitVector
            #expect(v.x == unit.0 && v.y == unit.1 && v.z == unit.2)
        }
    }

    // MARK: - Validator rules

    static func node(_ refinements: [MeshRefinement]) -> ComponentNode {
        var node = ComponentNode(name: "part", shape: .primitive(.box))
        node.refinements = refinements
        return node
    }

    @Test func validatorAcceptsWellFormedOps() {
        let issues = SpecValidator.refinementIssues(Self.node([
            .taper(axis: .z, scale: 0.5),
            .bevel(width: 0.02, angleDegrees: 30),
            .extrude(direction: .posY, distance: 0.1),
        ]))
        #expect(issues.isEmpty)
    }

    @Test func validatorRejectsDegenerateParameters() {
        // Taper: non-finite, non-positive, and the no-op scale of exactly 1.
        for scale in [Double.nan, 0, -2, 1] {
            let issues = SpecValidator.refinementIssues(Self.node([.taper(axis: .x, scale: scale)]))
            #expect(issues.contains { $0.message.contains("taper scale") }, "scale \(scale)")
        }
        // Bevel: width must be > 0; angle must sit inside (0, 180).
        for op in [MeshRefinement.bevel(width: 0, angleDegrees: 30),
                   .bevel(width: .infinity, angleDegrees: 30)] {
            #expect(SpecValidator.refinementIssues(Self.node([op])).contains { $0.message.contains("bevel width") })
        }
        for angle in [0.0, 180, -5, Double.nan] {
            let issues = SpecValidator.refinementIssues(Self.node([.bevel(width: 0.1, angleDegrees: angle)]))
            #expect(issues.contains { $0.message.contains("bevel angle") }, "angle \(angle)")
        }
        // Extrude: distance must be finite and non-zero (sign chooses in/out).
        for distance in [0.0, Double.nan] {
            let issues = SpecValidator.refinementIssues(Self.node([.extrude(direction: .posX, distance: distance)]))
            #expect(issues.contains { $0.message.contains("extrude distance") }, "distance \(distance)")
        }
    }
}
