import Foundation
import SculptKit
import MeshKit
import Testing
import USDCore
@testable import AgentMCP
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

/// Covers the verifiable-fidelity features wired into the AgentMCP `.sculpt`
/// group: real form-refinement/optimization mesh execution, the RasterLoader
/// decode + similarity, the imagePath intake, multi-view comparison-sheet
/// measurement, the review similarity floor, the AR-compliance completion
/// gate, and persistence/restore of pipeline state across store instances.
@Suite struct SculptVerifiableFidelityTests {

    static func specArg(_ spec: ObjectSculptSpec) -> JSONValue { try! JSONValue.parse(spec.encoded()) }

    // MARK: - PNG helpers (real files for the decode path)

    #if canImport(ImageIO)
    /// Write a `dim×dim` RGBA PNG to `url`, sampling a per-pixel colour closure.
    @discardableResult
    static func writePNG(_ url: URL, dim: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        var bytes = [UInt8](repeating: 0, count: dim * dim * 4)
        for y in 0..<dim {
            for x in 0..<dim {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * dim + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let cg = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func centeredSquarePNG(_ url: URL, dim: Int = 64, side: Int = 32) {
        let lo = (dim - side) / 2, hi = lo + side
        writePNG(url, dim: dim) { x, y in
            (x >= lo && x < hi && y >= lo && y < hi) ? (200, 200, 200, 255) : (0, 0, 0, 0)
        }
    }

    static func transparentPNG(_ url: URL, dim: Int = 64) {
        writePNG(url, dim: dim) { _, _ in (0, 0, 0, 0) }
    }
    #endif

    // MARK: - RasterLoader

    #if canImport(ImageIO)
    @Test func rasterLoaderDecodesAndMeasures() throws {
        let dir = Fixtures.tempDirectory()
        let ref = dir.appendingPathComponent("ref.png")
        let same = dir.appendingPathComponent("same.png")
        Self.centeredSquarePNG(ref)
        Self.centeredSquarePNG(same)

        let info = RasterLoader.info(path: ref.path)
        #expect(info?.width == 64)
        #expect(info?.height == 64)
        #expect(info?.hasAlpha == true)

        let report = RasterLoader.similarity(referencePath: ref.path, renderPath: same.path)
        #expect(report != nil)
        #expect(report!.aggregate > 0.99)
    }

    @Test func rasterLoaderReturnsNilForMissingFiles() {
        #expect(RasterLoader.load(path: "/no/such/file.png") == nil)
        #expect(RasterLoader.info(path: "/no/such/file.png") == nil)
        #expect(RasterLoader.similarity(referencePath: "/nope.png", renderPath: "/nope2.png") == nil)
        #expect(RasterLoader.worstViewSimilarity([(reference: "/nope.png", render: "/nope2.png")]) == nil)
    }

    @Test func worstViewSimilarityEmptyIsNil() {
        #expect(RasterLoader.worstViewSimilarity([]) == nil)
    }

    @Test func worstViewSimilarityPicksWorst() throws {
        let dir = Fixtures.tempDirectory()
        let ref = dir.appendingPathComponent("ref.png")
        let good = dir.appendingPathComponent("good.png")
        let bad = dir.appendingPathComponent("bad.png")
        Self.centeredSquarePNG(ref)
        Self.centeredSquarePNG(good)
        Self.transparentPNG(bad)
        let worst = RasterLoader.worstViewSimilarity([
            (reference: ref.path, render: good.path),
            (reference: ref.path, render: bad.path),
        ])
        #expect(worst != nil)
        #expect(worst!.silhouetteIoU == 0)   // dragged down by the empty render
    }
    #endif

    // MARK: - imagePath intake

    #if canImport(ImageIO)
    @Test func probeAndAssessDecodeImagePath() async throws {
        let dir = Fixtures.tempDirectory()
        let ref = dir.appendingPathComponent("ref.png")
        Self.writePNG(ref, dim: 128) { _, _ in (10, 20, 30, 255) }
        let server = Fixtures.server(session: Fixtures.session())

        let probe = await callOK(server, "sculpt_probe", ["imagePath": .string(ref.path)])
        #expect(probe["width"].doubleValue == 128)
        #expect(probe["height"].doubleValue == 128)

        let assess = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "imagePath": .string(ref.path)])
        #expect(assess["objectClass"].stringValue == "object")
    }
    #endif

    @Test func intakeRejectsUndecodableImagePath() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callError(server, "sculpt_probe", ["imagePath": "/no/such/img.png"])
        _ = await callError(server, "sculpt_assess", ["hints": ["x"], "imagePath": "/no/such/img.png"])
    }

    @Test func intakeFallsBackToExplicitDimensions() async {
        let server = Fixtures.server(session: Fixtures.session())
        let probe = await callOK(server, "sculpt_probe", ["width": 256, "height": 256])
        #expect(probe["width"].doubleValue == 256)
        // Neither imagePath nor dimensions → error.
        _ = await callError(server, "sculpt_probe", [:])
    }

    // MARK: - Real mesh refinement / decimation executors

    @Test func refineMeshStepInsetsRealGeometry() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "G", parentPath: nil), session: session)
        _ = try await SculptTools.execute(
            step: .createMesh(name: "M", parentPath: "/G", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 8),
            session: session)
        let before = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath("/G/M")!)!)
        let refined = try await SculptTools.execute(
            step: .refineMesh(path: "/G/M", ops: [.inset(fraction: 0.3, depth: -0.1)]), session: session)
        #expect(refined == "/G/M")
        let after = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath("/G/M")!)!)
        // Inset genuinely adds geometry — the point count grows.
        #expect(after.points.count > before.points.count)
    }

    /// Two triangles that share an edge but carry *duplicated* split vertices
    /// at the shared corners — exactly the seam duplication the optimization
    /// weld is meant to clean up. Six points, two coincident pairs.
    static func seamDuplicatedMesh() throws -> HalfEdgeMesh {
        let flat = FlatMesh(
            points: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),   // triangle A
                SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),   // triangle B (2 dups)
            ],
            faceVertexCounts: [3, 3],
            faceVertexIndices: [0, 1, 2, 3, 4, 5])
        return try MeshIO.mesh(from: flat)
    }

    @Test func decimateMeshStepWeldsCoincidentVertices() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "G", parentPath: nil), session: session)
        let path = try SculptTools.insertMesh(
            try Self.seamDuplicatedMesh(), name: "Seam", parentPath: "/G", session: session)
        let before = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath(path)!)!)
        #expect(before.points.count == 6)

        // A small weld epsilon folds the two coincident seam pairs (6 → 4).
        let decimated = try await SculptTools.execute(
            step: .decimateMesh(path: path, weldDistance: 0.001), session: session)
        #expect(decimated == path)
        let after = try GeometryProbe.flatMesh(of: session.stage.prim(at: PrimPath(path)!)!)
        #expect(after.points.count == 4)          // duplicates removed
        #expect(after.faceVertexCounts.count == 2) // both triangles survive
    }

    @Test func decimateRefusesWhenNothingToWeld() async throws {
        // A clean box has no coincident vertices, so a tiny weld has nothing to
        // fold — MeshKit refuses and the executor surfaces a clean error rather
        // than silently collapsing geometry.
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "G", parentPath: nil), session: session)
        _ = try await SculptTools.execute(
            step: .createMesh(name: "Bx", parentPath: "/G", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 4),
            session: session)
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(step: .decimateMesh(path: "/G/Bx", weldDistance: 0.001), session: session)
        }
    }

    @Test func meshTransformThrowsForMissingPrim() async {
        let session = Fixtures.session()
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .refineMesh(path: "/Nope", ops: [.inset(fraction: 0.3, depth: 0)]), session: session)
        }
    }

    @Test func meshTransformThrowsForNonMeshPrim() async throws {
        // The prim exists but carries no mesh topology (it's a group/Xform), so
        // the read-back fails with a clear "cannot read mesh" error.
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "G", parentPath: nil), session: session)
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .refineMesh(path: "/G", ops: [.inset(fraction: 0.3, depth: 0)]), session: session)
        }
    }

    @Test func formRefinementPassRunsEndToEnd() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld,
                                 refinements: [.inset(fraction: 0.3, depth: -0.05)])
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(spec)])
        _ = await callOK(server, "sculpt_build_pass")                       // blockout
        _ = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png"])                          // → structural
        _ = await callOK(server, "sculpt_build_pass")                       // structural
        _ = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png"])                          // → formRefinement
        let refine = await callOK(server, "sculpt_build_pass")              // formRefinement
        #expect(refine["pass"].stringValue == "formRefinement")
        #expect(refine["reviewOnly"].boolValue == false)                   // real work now
        #expect(refine["stepCount"].doubleValue == 1)
    }

    // MARK: - Comparison sheet measurement

    #if canImport(ImageIO)
    @Test func comparisonSheetMeasuresSimilarity() async throws {
        let dir = Fixtures.tempDirectory()
        let ref = dir.appendingPathComponent("ref.png")
        let render = dir.appendingPathComponent("render.png")
        Self.centeredSquarePNG(ref)
        Self.centeredSquarePNG(render)
        let server = Fixtures.server(session: Fixtures.session(), configuration: .init(workDirectory: dir))
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        let out = await callOK(server, "sculpt_comparison_sheet",
            ["referencePath": .string(ref.path), "renderPath": .string(render.path)])
        #expect(out["measuredSimilarity"].doubleValue ?? 0 > 0.99)
        #expect(out["viewCount"].doubleValue == 1)
        #expect(out["similarity"]["silhouetteIoU"].doubleValue == 1)
    }

    @Test func comparisonSheetMultiViewWorstWins() async throws {
        let dir = Fixtures.tempDirectory()
        let ref = dir.appendingPathComponent("ref.png")
        let good = dir.appendingPathComponent("good.png")
        let bad = dir.appendingPathComponent("bad.png")
        Self.centeredSquarePNG(ref)
        Self.centeredSquarePNG(good)
        Self.transparentPNG(bad)
        let server = Fixtures.server(session: Fixtures.session(), configuration: .init(workDirectory: dir))
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        let out = await callOK(server, "sculpt_comparison_sheet", [
            "views": .array([
                // First view omits its label → the default "view1" label is used.
                .object(["referencePath": .string(ref.path), "renderPath": .string(good.path)]),
                .object(["label": "back", "referencePath": .string(ref.path), "renderPath": .string(bad.path)]),
            ]),
        ])
        #expect(out["viewCount"].doubleValue == 2)
        // Worst (empty) view drives the measured similarity down.
        #expect(out["measuredSimilarity"].doubleValue ?? 1 < 0.6)
    }
    #endif

    @Test func comparisonSheetUndecodableReportsNoMeasurement() async {
        let dir = Fixtures.tempDirectory()
        let server = Fixtures.server(session: Fixtures.session(), configuration: .init(workDirectory: dir))
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        let out = await callOK(server, "sculpt_comparison_sheet",
            ["referencePath": "/no/ref.png", "renderPath": "/no/render.png"])
        #expect(out["measuredSimilarity"] == .null)
        #expect(out["similarityNote"].stringValue?.isEmpty == false)
    }

    @Test func comparisonSheetRejectsMissingPair() async {
        let dir = Fixtures.tempDirectory()
        let server = Fixtures.server(session: Fixtures.session(), configuration: .init(workDirectory: dir))
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        _ = await callError(server, "sculpt_comparison_sheet", ["referencePath": "/only/ref.png"])
        _ = await callError(server, "sculpt_comparison_sheet",
            ["views": .array([.object(["label": "x"])])])
    }

    @Test func comparisonSheetBeforeAuthorErrors() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callError(server, "sculpt_comparison_sheet",
            ["referencePath": "/a.png", "renderPath": "/b.png"])
    }

    // MARK: - Review similarity floor

    @Test func reviewEnforcesSimilarityFloorWhenAssessed() async {
        let server = Fixtures.server(session: Fixtures.session())
        // Assess → policy carries a 0.5 floor.
        _ = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "width": 512, "height": 512])
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        // The untextured passes (blockout, structural, formRefinement) defer the
        // colour-dependent similarity floor — evidence-only continues advance
        // through them up to `material`, the first textured pass.
        for expected in ["structural", "formRefinement", "material"] {
            let step = await callOK(server, "sculpt_review",
                ["decision": "continue", "score": 0.9, "renderPath": "/tmp/r.png",
                 "comparisonSheetPath": "/tmp/c.png"])
            #expect(step["result"].stringValue == "advanced")
            #expect(step["currentPass"].stringValue == expected)
        }
        // At `material` the floor bites: continue without a measured similarity
        // → rejected.
        let msg = await callError(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png"])
        #expect(msg.contains("similarity"))
        // Low measured similarity → rejected.
        _ = await callError(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.2])
        // Sufficient measured similarity → advances.
        let ok = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.8])
        #expect(ok["result"].stringValue == "advanced")
    }

    @Test func statusReportsSimilarityFields() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "width": 512, "height": 512])
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(SculptToolTests.richSpec())])
        _ = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.83])
        let status = await callOK(server, "sculpt_status")
        #expect(status["similarityFloor"].doubleValue == 0.5)
        #expect(status["lastMeasuredSimilarity"].doubleValue == 0.83)
    }

    // MARK: - AR-compliance completion gate

    /// A grounded, materialed spec that authors a clean AR-valid stage.
    static func compliantSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), materialID: "steel", attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        var spec = ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "steel", baseColor: [0.6, 0.6, 0.6], roughness: 0.4, metallic: 1)],
            colliders: [Collider(name: "hull", kind: .box, component: "Body")])
        spec.detailInventory.upsert(
            DetailItem(id: "sheen", description: "metal sheen", kind: .gloss, mappedTo: "steel"))
        spec.detailInventory.upsert(
            DetailItem(id: "edge", description: "beveled edge", kind: .bevel, mappedTo: "Body"))
        return spec
    }

    /// Drive to the final pass, building each authoring pass so the stage is
    /// real, passing the similarity floor at every continue.
    func driveToFinalPass(_ server: MCPServer) async {
        for _ in 0..<7 {
            _ = await callOK(server, "sculpt_build_pass")
            _ = await callOK(server, "sculpt_review",
                ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
                 "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.9])
        }
    }

    @Test func completionGateBlocksNonCompliantStage() async {
        // Assessed (requireCompliance = true) over a stage whose defaultPrim
        // points at a nonexistent prim — a hard ARKit error → completion blocked.
        let server = Fixtures.server(session: Fixtures.nonCompliantSession())
        _ = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "width": 512, "height": 512])
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.compliantSpec())])
        for _ in 0..<7 {
            _ = await callOK(server, "sculpt_review",
                ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
                 "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.9])
        }
        let msg = await callError(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.9])
        #expect(msg.contains("AR-compliance"))
    }

    @Test func completionGateAllowsCompliantStage() async {
        let session = Fixtures.emptySession()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "width": 512, "height": 512])
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.compliantSpec())])
        await driveToFinalPass(server)
        let done = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png", "measuredSimilarity": 0.9])
        #expect(done["result"].stringValue == "completed")
    }

    @Test func completionGateSkippedWithoutAssessment() async {
        // No assess → requireCompliance defaults off → completion allowed even
        // with an unbuilt stage (legacy behaviour preserved).
        let server = Fixtures.server(session: Fixtures.emptySession())
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.compliantSpec())])
        for _ in 0..<7 {
            _ = await callOK(server, "sculpt_review",
                ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
                 "comparisonSheetPath": "/tmp/c.png"])
        }
        let done = await callOK(server, "sculpt_review",
            ["decision": "continue", "score": 0.95, "renderPath": "/tmp/r.png",
             "comparisonSheetPath": "/tmp/c.png"])
        #expect(done["result"].stringValue == "completed")
    }

    // MARK: - Persistence / restore

    @Test func storeRestoresStateAcrossInstances() async throws {
        let dir = Fixtures.tempDirectory()
        // First store: assess, author, advance one pass.
        let store1 = SculptStore(workDirectory: dir)
        await store1.setAssessment(PreSpecAssessment.assess(hints: ["barrel"], width: 512, height: 512))
        await store1.setSpec(SculptToolTests.richSpec())
        _ = try await store1.review(
            decision: .continue, score: 0.95, renderPath: "/tmp/r.png",
            comparisonSheetPath: "/tmp/c.png", measuredSimilarity: 0.8, note: nil,
            threshold: 0.7, similarityFloor: 0.5)

        // A fresh store over the same directory restores spec + pass position.
        let store2 = SculptStore(workDirectory: dir)
        let restoredSpec = await store2.spec
        let restoredOrchestrator = await store2.orchestrator
        let restoredAssessment = await store2.assessment
        #expect(restoredSpec?.name == "Sculpt")
        #expect(restoredOrchestrator?.current == .structural)   // not reset to blockout
        #expect(restoredAssessment?.policy.similarityFloor == 0.5)
        #expect(restoredSpec?.reviewHistory.count == 1)
    }

    @Test func storeWithoutDirectoryIsEphemeral() async {
        let store = SculptStore(workDirectory: nil)
        await store.setSpec(SculptToolTests.richSpec())
        #expect(await store.spec != nil)
        // Nothing persisted → a new nil-dir store starts empty.
        let fresh = SculptStore(workDirectory: nil)
        #expect(await fresh.spec == nil)
    }

    @Test func storeIgnoresEmptyDirectory() async {
        let dir = Fixtures.tempDirectory()
        let store = SculptStore(workDirectory: dir)
        #expect(await store.spec == nil)
        #expect(await store.assessment == nil)
        #expect(await store.isFinalPass == false)
    }

    @Test func storeRecoversSpecWithoutOrchestratorFile() async throws {
        // Simulate a partial write / crash between persists: the spec file
        // exists but the orchestrator file does not. Restore must recover by
        // restarting the pass machine at blockout rather than stranding the spec.
        let dir = Fixtures.tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SculptToolTests.richSpec().encoded()
            .write(to: dir.appendingPathComponent("sculpt-spec.json"))
        let store = SculptStore(workDirectory: dir)
        #expect(await store.spec != nil)
        #expect(await store.orchestrator?.current == .blockout)
    }
}


