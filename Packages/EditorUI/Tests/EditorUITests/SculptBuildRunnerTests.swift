import Testing
import USDCore
import SculptKit
@testable import EditorUI

/// `SculptBuildRunner` applies SculptKit `BuildStep`s to the open document as
/// live, undoable commands — the in-app path that renders the sculpt build in
/// the viewport without a file (specs/sculpt-pipeline.md).
@Suite("SculptBuildRunner")
@MainActor
struct SculptBuildRunnerTests {

    private func house() -> ObjectSculptSpec { SculptDemos.lowPolyHouse() }

    @Test func blockoutAuthorsGeometryTree() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let authored = SculptBuildRunner.apply(pass: .blockout, of: house(), to: doc)

        // Group House + walls/roof/door/2 windows/chimney = 7 prims.
        #expect(authored.count == 7)
        let houseRoot = doc.snapshot.rootPrims.first { $0.name == "House" }
        #expect(houseRoot?.typeName == "Xform")
        let walls = houseRoot?.children.first { $0.name == "Walls" }
        #expect(walls?.children.first?.typeName == "Mesh")
        // The repetition copy is a real prim.
        #expect(houseRoot?.children.contains { $0.name == "Window_bay1" } == true)
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
        let surface = doc.snapshot.prim(at: PrimPath("/Looks/Material/Surface")!)
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
        // createLight + setTransform both resolve to the light prim path.
        let authored = SculptBuildRunner.apply(pass: .lighting, of: spec, to: doc)
        #expect(authored == ["/House/Sun", "/House/Sun"])
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
}
