import Foundation
import MeshKit
import simd
import SculptKit
import Testing
import USDCore
@testable import AgentMCP

/// Sculpt-accuracy P4 (#85): the executor side of the new expressiveness ops —
/// the `refineMesh` step wiring that reads a prim back, runs the shared
/// `SculptKit.RefinementGeometry` resolver, and re-authors the result. The
/// resolver's geometry is covered in SculptKit's `RefinementGeometryTests`; the
/// declarative coding/validation side in `RefinementExpressivenessTests`.
@Suite struct SculptRefinementGeometryTests {

    // MARK: - refineMesh step wiring

    @Test func refineMeshStepRunsTheNewOpsEndToEnd() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "G", parentPath: nil), session: session)
        _ = try await SculptTools.execute(
            step: .createMesh(name: "M", parentPath: "/G", primitive: .box,
                              width: 2, height: 1, depth: 4, radius: 0.5, segments: 8),
            session: session)
        let before = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath("/G/M")!)!)

        // A wedge body with chamfered shoulder lines and a pulled nose — the
        // Aventador-profile combination F5 said the primitive set couldn't say.
        let refined = try await SculptTools.execute(
            step: .refineMesh(path: "/G/M", ops: [
                .taper(axis: .y, scale: 0.5),
                .bevel(width: 0.03, angleDegrees: 30),
                .extrude(direction: .posZ, distance: 0.4),
            ]), session: session)
        #expect(refined == "/G/M")
        let after = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath("/G/M")!)!)
        #expect(after.points.count > before.points.count)
        // The wedge survives the pipeline: narrower at the top than the base.
        let ys = after.points.map(\.y)
        let top = after.points.filter { $0.y > ys.max()! - 1e-6 }.map(\.x)
        let bottom = after.points.filter { $0.y < ys.min()! + 1e-6 }.map(\.x)
        #expect((top.max()! - top.min()!) < (bottom.max()! - bottom.min()!))

        // Executor failures surface as structured tool errors.
        await #expect(throws: ToolError.self) {
            _ = try await SculptTools.execute(
                step: .refineMesh(path: "/G/M", ops: [.extrude(direction: .posX, distance: 0)]),
                session: session)
        }
    }
}
