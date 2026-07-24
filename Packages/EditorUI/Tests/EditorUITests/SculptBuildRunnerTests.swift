import Testing
import USDCore
import EditingKit
import SculptKit
import ValidationKit
@testable import EditorUI

/// `SculptBuildRunner` applies SculptKit `BuildStep`s to the open document as
/// live, undoable commands — the in-app path that renders the sculpt build in
/// the viewport without a file (specs/sculpt-pipeline.md).
@Suite("SculptBuildRunner")
@MainActor
struct SculptBuildRunnerTests {

    private func house() -> ObjectSculptSpec { SculptDemos.lowPolyHouse() }

    /// #147: a material carrying a procedural facade bakes albedo + emissive
    /// PNGs and binds them onto the surface shader in the live-preview runner.
    @Test func createMaterialBakesFacade() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = SculptBuildRunner.apply(step: .createGroup(name: "Tower", parentPath: nil), to: doc)
        _ = SculptBuildRunner.apply(
            step: .createMesh(name: "Body", parentPath: "/Tower", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 8), to: doc)
        let facade = FacadeTexture(rows: 4, columns: 4, litFraction: 0.5, resolution: 32)
        let path = SculptBuildRunner.apply(
            step: .createMaterial(targetPath: "/Tower/Body",
                                  material: MaterialSpec(id: "facade_mat", baseColor: [0.1, 0.1, 0.12],
                                                         facade: facade)), to: doc)
        // The material prim carries the sanitized spec id (#167), matching the
        // MCP executor; the baked file stem derives from the same id.
        #expect(path == "/Looks/facade_mat")

        let surface = doc.snapshot.prim(at: PrimPath("/Looks/facade_mat/Surface")!)
        func mapPath(_ name: String) -> String? {
            if case let .string(s)? = surface?.attribute(named: name)?.value { return s }
            return nil
        }
        #expect(mapPath("inputs:albedoMap")?.hasSuffix("facade_mat_albedo.png") == true)
        #expect(mapPath("inputs:emissiveMap")?.hasSuffix("facade_mat_emissive.png") == true)
    }

    /// #167: the in-app executor names the material prim after the spec id and
    /// mints exactly one `/Looks` prim per spec material, even when several
    /// components share that id — no `Material_1…Material_N` trail.
    @Test func createMaterialMintsOnePrimPerSpecID() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = SculptBuildRunner.apply(step: .createGroup(name: "G", parentPath: nil), to: doc)
        for name in ["A", "B", "C"] {
            _ = SculptBuildRunner.apply(
                step: .createMesh(name: name, parentPath: "/G", primitive: .box,
                                  width: 1, height: 1, depth: 1, radius: 0.5, segments: 8), to: doc)
        }
        let shared = MaterialSpec(id: "red paint", baseColor: [0.8, 0.1, 0.1])
        let paths = ["A", "B", "C"].map {
            SculptBuildRunner.apply(step: .createMaterial(targetPath: "/G/\($0)", material: shared), to: doc)
        }

        // Every component resolved to the same sanitized, spec-named prim.
        #expect(paths.allSatisfy { $0 == "/Looks/red_paint" })
        let looks = doc.snapshot.rootPrims.first { $0.name == "Looks" }
        #expect(looks?.children.count == 1)
        #expect(looks?.children.first?.name == "red_paint")
        // Each component still carries the binding.
        for name in ["A", "B", "C"] {
            let bound = MaterialBinding.materialPath(for: PrimPath("/G/\(name)")!, in: doc.snapshot)
            #expect(bound?.description == "/Looks/red_paint")
        }
    }

    /// #158/#167 replay hygiene: re-running the material pass (as a refine loop
    /// does) re-binds the existing prim instead of minting duplicates.
    @Test func createMaterialReplayReusesExistingPrim() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = SculptBuildRunner.apply(step: .createGroup(name: "G", parentPath: nil), to: doc)
        _ = SculptBuildRunner.apply(
            step: .createMesh(name: "M", parentPath: "/G", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 8), to: doc)
        let step = BuildStep.createMaterial(
            targetPath: "/G/M", material: MaterialSpec(id: "blade_metal", baseColor: [0.6, 0.6, 0.65]))

        let first = SculptBuildRunner.apply(step: step, to: doc)
        let second = SculptBuildRunner.apply(step: step, to: doc)

        #expect(first == "/Looks/blade_metal")
        #expect(second == "/Looks/blade_metal")
        #expect(doc.snapshot.rootPrims.first { $0.name == "Looks" }?.children.count == 1)
    }

    /// A material without a facade is authored unchanged (no baked maps).
    @Test func createMaterialWithoutFacadeAuthorsNoMaps() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = SculptBuildRunner.apply(step: .createGroup(name: "G", parentPath: nil), to: doc)
        _ = SculptBuildRunner.apply(
            step: .createMesh(name: "M", parentPath: "/G", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 8), to: doc)
        _ = SculptBuildRunner.apply(
            step: .createMaterial(targetPath: "/G/M",
                                  material: MaterialSpec(id: "plain", baseColor: [0.2, 0.2, 0.2])), to: doc)
        let surface = doc.snapshot.prim(at: PrimPath("/Looks/plain/Surface")!)
        #expect(surface?.attribute(named: "inputs:albedoMap") == nil)
    }

    @Test func blockoutAuthorsGeometryTree() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let authored = SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)

        // Group House + walls/roof/door/2 windows/chimney = 7 distinct prims.
        // The blockout pass now emits a create step *and* a place (setTransform)
        // step per component (issue #115), so `apply` returns two paths per prim;
        // the geometry tree still has exactly 7 unique prims.
        #expect(Set(authored).count == 7)
        let houseRoot = doc.snapshot.rootPrims.first { $0.name == "House" }
        #expect(houseRoot?.typeName == "Xform")
        let walls = houseRoot?.children.first { $0.name == "Walls" }
        #expect(walls?.children.first?.typeName == "Mesh")
        // The repetition copy is a real prim.
        #expect(houseRoot?.children.contains { $0.name == "Window_bay1" } == true)
    }

    /// Sculpt-accuracy P5 (#86): a rebuilt stage must author real per-vertex
    /// normals, so `MissingNormalsRule` reports zero `mesh.normals` diagnostics.
    @Test func builtMeshesAuthorNormals() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)

        let meshes = doc.snapshot.allPrims().filter { $0.typeName == "Mesh" }
        #expect(!meshes.isEmpty)
        // Every authored mesh carries a normals channel parallel to its points.
        for mesh in meshes {
            guard case .float3Array(let points)? = mesh.attribute(named: "points")?.value,
                  case .float3Array(let normals)? = mesh.attribute(named: "normals")?.value
            else { Issue.record("\(mesh.name) missing points/normals"); continue }
            #expect(normals.count == points.count)
        }

        let diagnostics = MissingNormalsRule().evaluate(stage: doc.snapshot)
        #expect(diagnostics.isEmpty)
    }

    /// Deforming a built mesh re-authors normals for the new surface rather than
    /// leaving the pre-transform channel stale.
    @Test func deformedMeshRefreshesNormals() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        let target = doc.snapshot.allPrims().first {
            $0.typeName == "Xform" && $0.children.contains { $0.typeName == "Mesh" }
        }
        let xformPath = target!.path.description
        let before = SculptBuildRunner.applyMeshTransform(at: xformPath, to: doc) { mesh in
            var m = mesh
            for v in m.vertexOrder {
                var p = m.positions[v]!
                p.y *= 2
                m.setPosition(p, for: v)
            }
            return m
        }
        #expect(before != nil)
        let geo = doc.snapshot.prim(at: PrimPath(xformPath)!.appending("Geo")!)
        #expect(geo?.attribute(named: "normals") != nil)
        #expect(MissingNormalsRule().evaluate(stage: doc.snapshot).isEmpty)
    }

    @Test func structuralPlacesAndMaterialBinds() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        let placed = SculptBuildRunner.apply(pass: .structural, of: house(), to: doc)
        #expect(!placed.isEmpty)
        // Roof got a non-identity transform (translated up).
        let roof = doc.snapshot.prim(at: PrimPath("/House/Roof")!)
        #expect(roof?.attribute(named: "xformOp:transform") != nil)

        let materials = SculptBuildRunner.apply(pass: .material, of: house(), to: doc)
        #expect(!materials.isEmpty)   // painted leaves bound
    }

    /// Material pass on a painted node WITH a repetition shares the base's one
    /// material with each copy via `.bindMaterial`, rather than minting a
    /// duplicate material per copy (#140).
    @Test func materialPassSharesOneMaterialAcrossRepetitionCopies() {
        let painted = ComponentNode(
            name: "Bar", shape: .primitive(.box), materialID: "steel",
            repetition: RepetitionSystem(name: "row", count: 3, step: [1, 0, 0]))
        let root = ComponentNode(name: "Rack", shape: .group, children: [painted])
        let spec = ObjectSculptSpec(
            name: "Rack", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "steel", baseColor: [0.6, 0.6, 0.6])])

        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        SculptBuildRunner.apply(pass: .structural, of: spec, to: doc)
        let materials = SculptBuildRunner.apply(pass: .material, of: spec, to: doc)
        #expect(!materials.isEmpty)

        // The base and both copies resolve to the SAME single material.
        let base = MaterialBinding.materialPath(for: PrimPath("/Rack/Bar")!, in: doc.snapshot)
        let copy1 = MaterialBinding.materialPath(for: PrimPath("/Rack/Bar_row1")!, in: doc.snapshot)
        let copy2 = MaterialBinding.materialPath(for: PrimPath("/Rack/Bar_row2")!, in: doc.snapshot)
        #expect(base != nil)
        #expect(copy1 == base)
        #expect(copy2 == base)

        // Only one Material prim was authored (no per-copy duplicates).
        let mats = doc.snapshot.allPrims().filter { $0.typeName == "Material" }
        #expect(mats.count == 1)
    }

    @Test func playLiveRunsEveryPass() async {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        await SculptBuildRunner.playLive(house(), into: doc, passDelay: .milliseconds(1))
        let houseRoot = doc.snapshot.rootPrims.first { $0.name == "House" }
        #expect(houseRoot != nil)
        #expect(doc.canUndo)
    }

    @Test func skipsDuplicateAndInvalidSteps() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        let countAfterFirst = doc.snapshot.rootPrims.count
        // Re-running blockout is idempotent (existing sibling names are skipped).
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        #expect(doc.snapshot.rootPrims.count == countAfterFirst)

        // A transform step for a missing prim is skipped, not fatal.
        #expect(SculptBuildRunner.apply(
            step: .setTransform(path: "/Ghost", translation: [0, 0, 0],
                                rotationEulerDegrees: [0, 0, 0], scale: [1, 1, 1]),
            to: doc) == nil)
        // An unknown library entry is skipped.
        #expect(SculptBuildRunner.apply(
            step: .createLibraryMesh(name: "X", parentPath: nil, entryID: "prefab.ghost"),
            to: doc) == nil)
    }

    @Test func authorsRuntimeManifestAndSkipsMissingRoot() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)
        // Author the runtime manifest onto the existing root.
        let path = SculptBuildRunner.apply(
            step: .authorRuntime(rootPath: "/House", manifestJSON: "{\"nodes\":[\"House\"]}"),
            to: doc)
        #expect(path == "/House")
        #expect(doc.snapshot.prim(at: PrimPath("/House")!)?.attribute(named: "sculptRuntime") != nil)
        // A missing root prim is skipped, not fatal.
        #expect(SculptBuildRunner.apply(
            step: .authorRuntime(rootPath: "/Ghost", manifestJSON: "{}"), to: doc) == nil)
    }

    /// A spec whose leaf carries a fully-textured material, exercising every
    /// extra channel the material pass authors onto the surface shader.
    private func texturedSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), materialID: "pbr")
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            materials: [MaterialSpec(
                id: "pbr", baseColor: [0.5, 0.5, 0.5], roughness: 0.4, metallic: 0.2,
                emissive: [0.1, 0, 0], albedoMap: "albedo.png", normalMap: "normal.png",
                roughnessMap: "rough.png", emissiveMap: "emit.png", normalScale: 0.75)])
    }

    @Test func materialPassAuthorsTextureChannels() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let spec = texturedSpec()
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let materials = SculptBuildRunner.apply(pass: .material, of: spec, to: doc)
        #expect(!materials.isEmpty)
        let surface = doc.snapshot.prim(at: PrimPath("/Looks/pbr/Surface")!)
        #expect(surface?.attribute(named: "inputs:roughness") != nil)
        #expect(surface?.attribute(named: "inputs:metallic") != nil)
        #expect(surface?.attribute(named: "inputs:emissiveColor") != nil)
        #expect(surface?.attribute(named: "inputs:albedoMap") != nil)
        #expect(surface?.attribute(named: "inputs:normalMap") != nil)
        #expect(surface?.attribute(named: "inputs:roughnessMap") != nil)
        #expect(surface?.attribute(named: "inputs:emissiveMap") != nil)
        #expect(surface?.attribute(named: "inputs:normalScale") != nil)
    }

    @Test func surfacePassAuthorsProjectedTextureDescriptor() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        var spec = texturedSpec()
        spec.surfaceProjection = SurfaceProjection(
            targetComponent: "Body",
            camera: CameraPose(position: [0, 0, 5], target: [0, 0, 0]))
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let authored = SculptBuildRunner.apply(pass: .surface, of: spec, to: doc)
        #expect(authored == ["/Obj"])
        #expect(doc.snapshot.prim(at: PrimPath("/Obj")!)?.attribute(named: "sculptProjectedTexture") != nil)
    }

    @Test func projectTextureSkipsMissingAndInvalidRoot() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        // Missing root prim → skipped.
        #expect(SculptBuildRunner.apply(
            step: .projectTexture(rootPath: "/Ghost", descriptorJSON: "{}"), to: doc) == nil)
        // Unparseable path → skipped (PrimPath init fails).
        #expect(SculptBuildRunner.apply(
            step: .projectTexture(rootPath: "", descriptorJSON: "{}"), to: doc) == nil)
    }

    @Test func demoHouseSpecIsStrictQualityValid() {
        let spec = house()
        let assessment = PreSpecAssessment.assess(
            hints: ["cute low poly house", "cottage", "red roof"], width: 800, height: 600)
        let result = SpecValidator.validate(spec, assessment: assessment, strictQuality: true)
        #expect(result.isValid)
    }

    @Test func lightingPassAuthorsRealLightPrim() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let spec = house()
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)   // creates /House
        // createLight + setTransform both resolve to the light prim path; the
        // runner now reports distinct authored prim paths, so it appears once.
        let authored = SculptBuildRunner.apply(pass: .lighting, of: spec, to: doc)
        #expect(authored == ["/House/Sun"])
        let light = doc.snapshot.prim(at: PrimPath("/House/Sun")!)
        #expect(light?.typeName == "DistantLight")
        #expect(light?.attribute(named: "inputs:intensity") != nil)
        #expect(light?.attribute(named: "inputs:color") != nil)
    }

    @Test func optimizationPassAuthorsLODManifest() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let spec = house()
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let authored = SculptBuildRunner.apply(pass: .optimization, of: spec, to: doc)
        #expect(authored == ["/House"])
        #expect(doc.snapshot.prim(at: PrimPath("/House")!)?.attribute(named: "sculptLOD") != nil)
    }

    @Test func lightPrimSkipsInvalidPath() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        // Unparseable path → skipped (PrimPath init fails on the space).
        #expect(SculptBuildRunner.apply(
            step: .createLight(name: "bad name", parentPath: nil, kind: .dome,
                               intensity: 1, color: [1, 1, 1]), to: doc) == nil)
    }

    // MARK: - Real geometry passes (form refinement + optimization weld)

    /// A grounded box spec that declares a real inset refinement on its leaf.
    private func refinedBoxSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld,
                                 refinements: [.inset(fraction: 0.3, depth: -0.05)])
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
    }

    @Test func formRefinementInsetsLiveGeometry() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let spec = refinedBoxSpec()
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let before = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let beforePts)? = before?.attribute(named: "points")?.value else {
            Issue.record("no points before refinement"); return
        }
        let authored = SculptBuildRunner.apply(pass: .formRefinement, of: spec, to: doc)
        #expect(authored == ["/Obj/Body"])
        let after = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let afterPts)? = after?.attribute(named: "points")?.value else {
            Issue.record("no points after refinement"); return
        }
        // Inset adds a recessed inner ring per face — real new geometry.
        #expect(afterPts.count > beforePts.count)
    }

    @Test func formRefinementSubdividesLiveGeometry() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld,
                                 refinements: [.subdivide(levels: 1)])
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let before = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let beforePts)? = before?.attribute(named: "points")?.value else {
            Issue.record("no points before refinement"); return
        }
        let authored = SculptBuildRunner.apply(pass: .formRefinement, of: spec, to: doc)
        #expect(authored == ["/Obj/Body"])
        let after = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let afterPts)? = after?.attribute(named: "points")?.value else {
            Issue.record("no points after refinement"); return
        }
        // Catmull-Clark introduces face/edge points — real new geometry.
        #expect(afterPts.count > beforePts.count)
    }

    /// P4 (#85) expressiveness ops through the in-app runner: taper, bevel, and
    /// extrude must reach the shared `SculptKit.RefinementGeometry` resolver the
    /// same way the AgentMCP executor does, and author real new geometry.
    @Test func formRefinementAppliesExpressivenessOpsLive() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld,
                                 refinements: [
                                    .taper(axis: .y, scale: 0.5),
                                    .bevel(width: 0.03, angleDegrees: 30),
                                    .extrude(direction: .posY, distance: 0.2),
                                 ])
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let before = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let beforePts)? = before?.attribute(named: "points")?.value else {
            Issue.record("no points before refinement"); return
        }
        let authored = SculptBuildRunner.apply(pass: .formRefinement, of: spec, to: doc)
        #expect(authored == ["/Obj/Body"])
        let after = doc.snapshot.prim(at: PrimPath("/Obj/Body/Geo")!)
        guard case .float3Array(let afterPts)? = after?.attribute(named: "points")?.value else {
            Issue.record("no points after refinement"); return
        }
        // Bevel + extrude add faces/vertices; the mesh grows.
        #expect(afterPts.count > beforePts.count)
    }

    @Test func optimizationWeldsCoincidentVerticesLive() {
        // A spec whose leaf is a box (no coincident verts) with a weld epsilon:
        // MeshKit refuses to weld nothing, so the step is skipped best-effort,
        // and the LOD manifest still authors. The runner never crashes.
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        let spec = ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            lodTiers: [LODTier(name: "lo", screenCoverage: 0.2, decimation: 0.3)],
            optimization: OptimizationSpec(weldDistance: 0.001))
        SculptBuildRunner.apply(pass: .blockout, of: spec, to: doc)
        let authored = SculptBuildRunner.apply(pass: .optimization, of: spec, to: doc)
        // The decimate step no-ops (nothing to weld) but the LOD manifest lands.
        #expect(doc.snapshot.prim(at: PrimPath("/Obj")!)?.attribute(named: "sculptLOD") != nil)
        #expect(authored.contains("/Obj"))
    }

    @Test func meshTransformSkipsMissingPrim() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        // Missing prim → skipped (returns nil, not fatal).
        #expect(SculptBuildRunner.apply(
            step: .refineMesh(path: "/Ghost", ops: [.inset(fraction: 0.3, depth: 0)]), to: doc) == nil)
        #expect(SculptBuildRunner.apply(
            step: .decimateMesh(path: "/Ghost", weldDistance: 0.01), to: doc) == nil)
        // Unparseable path → skipped.
        #expect(SculptBuildRunner.apply(
            step: .refineMesh(path: "", ops: []), to: doc) == nil)
    }
}
