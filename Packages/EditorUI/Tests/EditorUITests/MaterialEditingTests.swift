import Testing
import USDCore
import EditingKit
@testable import EditorUI

/// /Looks/Paint bound to /Car/Body, which /Car/Body/Trim inherits.
@MainActor
private func paintedCarDocument() -> EditorDocument {
    let paint = Prim(path: PrimPath("/Looks/Paint")!, typeName: "Material", attributes: [
        Attribute(name: "inputs:roughness", value: .double(0.4)),
    ])
    let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [paint])
    let trim = Prim(path: PrimPath("/Car/Body/Trim")!, typeName: "Mesh")
    let body = Prim(
        path: PrimPath("/Car/Body")!, typeName: "Mesh",
        relationships: [Relationship(name: "material:binding", targets: [paint.path])],
        children: [trim])
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body])
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [looks, car]))
}

/// The real-file shape: /Looks/Paint's inputs live on a Shader child.
@MainActor
private func shaderBackedDocument() -> EditorDocument {
    let shader = Prim(path: PrimPath("/Looks/Paint/Surface")!, typeName: "Shader", attributes: [
        Attribute(name: "info:id", value: .token("UsdPreviewSurface")),
        Attribute(name: "inputs:roughness", value: .double(0.4)),
    ])
    let paint = Prim(path: PrimPath("/Looks/Paint")!, typeName: "Material", children: [shader])
    let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [paint])
    let body = Prim(
        path: PrimPath("/Car/Body")!, typeName: "Mesh",
        relationships: [Relationship(name: "material:binding", targets: [paint.path])])
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [looks, body]))
}

/// A model with two distinct materials: /Looks/Paint on /Car/Body (inherited by
/// /Car/Body/Trim) and /Looks/Glass on /Car/Windows.
@MainActor
private func twoMaterialCarDocument() -> EditorDocument {
    let paint = Prim(path: PrimPath("/Looks/Paint")!, typeName: "Material", attributes: [
        Attribute(name: "inputs:diffuseColor", value: .vector([0.2, 0.2, 0.2])),
    ])
    let glass = Prim(path: PrimPath("/Looks/Glass")!, typeName: "Material")
    let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [paint, glass])
    let trim = Prim(path: PrimPath("/Car/Body/Trim")!, typeName: "Mesh")
    let bodyMesh = Prim(
        path: PrimPath("/Car/Body")!, typeName: "Mesh",
        relationships: [Relationship(name: "material:binding", targets: [paint.path])],
        children: [trim])
    let windows = Prim(
        path: PrimPath("/Car/Windows")!, typeName: "Mesh",
        relationships: [Relationship(name: "material:binding", targets: [glass.path])])
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [bodyMesh, windows])
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [looks, car]))
}

@Suite("EditorDocument model-wide recolor")
@MainActor
struct EditorDocumentRecolorTests {

    let car = PrimPath("/Car")!
    let paint = PrimPath("/Looks/Paint")!
    let glass = PrimPath("/Looks/Glass")!

    private func input(_ name: String) throws -> PreviewSurfaceInput {
        try #require(PreviewSurfaceInput.named(name))
    }

    @Test func gathersDistinctMaterialsUnderModelRoot() {
        let doc = twoMaterialCarDocument()
        let surfaces = Set(doc.materials(under: [car]).map(\.surfacePath))
        // Two distinct materials, deduped across the inheriting Trim part.
        #expect(surfaces == [paint, glass])
    }

    @Test func recolorSetsEveryMaterialInOneUndoStep() throws {
        let doc = twoMaterialCarDocument()
        let materials = doc.materials(under: [car])
        #expect(doc.recolorMaterials(materials, input: try input("diffuseColor"), to: .vector([1, 0, 0])))

        #expect(doc.snapshot.prim(at: paint)?.attribute(named: "inputs:diffuseColor")?.value == .vector([1, 0, 0]))
        #expect(doc.snapshot.prim(at: glass)?.attribute(named: "inputs:diffuseColor")?.value == .vector([1, 0, 0]))
        #expect(doc.undoLabel == "Recolor 2 materials")

        doc.undo()
        // Paint reverts to its prior colour; Glass back to no opinion.
        #expect(doc.snapshot.prim(at: paint)?.attribute(named: "inputs:diffuseColor")?.value == .vector([0.2, 0.2, 0.2]))
        #expect(doc.snapshot.prim(at: glass)?.attribute(named: "inputs:diffuseColor") == nil)
    }

    @Test func recolorNoOpsWhenNothingChanges() throws {
        let doc = twoMaterialCarDocument()
        // Only Paint has a diffuseColor, already this value; Glass has none, so
        // it does change — expect a run. Then re-applying the same is a no-op.
        _ = doc.recolorMaterials(doc.materials(under: [car]), input: try input("diffuseColor"), to: .vector([0.5, 0.5, 0.5]))
        #expect(!doc.recolorMaterials(doc.materials(under: [car]), input: try input("diffuseColor"), to: .vector([0.5, 0.5, 0.5])))
    }

    @Test func recolorEmptySelectionDoesNothing() throws {
        let doc = twoMaterialCarDocument()
        #expect(!doc.recolorMaterials([], input: try input("diffuseColor"), to: .vector([1, 0, 0])))
        #expect(!doc.canUndo)
    }
}

@Suite("EditorDocument material editing")
@MainActor
struct EditorDocumentMaterialTests {

    let paint = PrimPath("/Looks/Paint")!
    let body = PrimPath("/Car/Body")!
    let trim = PrimPath("/Car/Body/Trim")!

    private func input(_ name: String) throws -> PreviewSurfaceInput {
        try #require(PreviewSurfaceInput.named(name))
    }

    /// The material bound to `path`, as the inspector resolves it.
    private func material(_ doc: EditorDocument, _ path: PrimPath) throws -> ResolvedMaterial {
        try #require(doc.boundMaterial(for: path))
    }

    @Test func resolvesBoundMaterialForMesh() throws {
        let doc = paintedCarDocument()
        #expect(try material(doc, body).material.path == paint)
    }

    @Test func resolvesInheritedMaterialForChildPart() throws {
        let doc = paintedCarDocument()
        #expect(try material(doc, trim).material.path == paint)
    }

    @Test func unboundPrimHasNoMaterial() {
        let doc = paintedCarDocument()
        #expect(doc.boundMaterial(for: PrimPath("/Car")!) == nil)
    }

    @Test func materialInputReportsAuthoredValueOnly() throws {
        let doc = paintedCarDocument()
        let paint = try material(doc, body)
        #expect(doc.materialInput(try input("roughness"), on: paint) == .double(0.4))
        // Unauthored: nil, so the inspector can show the fallback + "default".
        #expect(doc.materialInput(try input("metallic"), on: paint) == nil)
    }

    @Test func setInputIsUndoable() throws {
        let doc = paintedCarDocument()
        let paint = try material(doc, body)
        #expect(doc.setMaterialInput(try input("roughness"), on: paint, to: .double(0.9)))
        #expect(doc.materialInput(try input("roughness"), on: paint) == .double(0.9))
        #expect(doc.undoLabel == "Set roughness on Paint")

        doc.undo()
        #expect(doc.materialInput(try input("roughness"), on: paint) == .double(0.4))
    }

    @Test func undoOfNewlyAuthoredInputLeavesNoOpinion() throws {
        let doc = paintedCarDocument()
        let paint = try material(doc, body)
        #expect(doc.setMaterialInput(try input("metallic"), on: paint, to: .double(1)))
        doc.undo()
        #expect(doc.materialInput(try input("metallic"), on: paint) == nil)
    }

    @Test func setInputClampsToRange() throws {
        let doc = paintedCarDocument()
        let paint = try material(doc, body)
        #expect(doc.setMaterialInput(try input("metallic"), on: paint, to: .double(7)))
        #expect(doc.materialInput(try input("metallic"), on: paint) == .double(1))
    }

    @Test func setInputRejectsWrongType() throws {
        let doc = paintedCarDocument()
        #expect(!doc.setMaterialInput(try input("metallic"), on: try material(doc, body), to: .vector([1, 0, 0])))
        #expect(!doc.canUndo)
    }

    @Test func setInputNoOpsOnUnchangedValue() throws {
        let doc = paintedCarDocument()
        #expect(!doc.setMaterialInput(try input("roughness"), on: try material(doc, body), to: .double(0.4)))
        #expect(!doc.canUndo)
    }

    @Test func clearInputRemovesAuthoredValueUndoably() throws {
        let doc = paintedCarDocument()
        let paint = try material(doc, body)
        #expect(doc.clearMaterialInput(try input("roughness"), on: paint))
        #expect(doc.materialInput(try input("roughness"), on: paint) == nil)
        #expect(doc.undoLabel == "Clear inputs:roughness")

        doc.undo()
        #expect(doc.materialInput(try input("roughness"), on: paint) == .double(0.4))
    }

    @Test func clearNoOpsOnUnauthoredInput() throws {
        let doc = paintedCarDocument()
        #expect(!doc.clearMaterialInput(try input("metallic"), on: try material(doc, body)))
        #expect(!doc.canUndo)
    }

    @Test func colorEditRoundTripsThroughSnapshot() throws {
        let doc = paintedCarDocument()
        #expect(doc.setMaterialInput(try input("diffuseColor"), on: try material(doc, body), to: .vector([0.8, 0.1, 0.1])))
        #expect(doc.snapshot.prim(at: paint)?.attribute(named: "inputs:diffuseColor")?.value
                == .vector([0.8, 0.1, 0.1]))
    }

    // MARK: Shader-backed materials (the shape real USD files use)

    @Test func editsShaderChildRatherThanMaterialPrim() throws {
        let doc = shaderBackedDocument()
        let paint = try material(doc, body)
        #expect(paint.hasDedicatedShader)

        #expect(doc.setMaterialInput(try input("metallic"), on: paint, to: .double(1)))
        let surface = PrimPath("/Looks/Paint/Surface")!
        #expect(doc.snapshot.prim(at: surface)?.attribute(named: "inputs:metallic")?.value == .double(1))
        // Authoring onto the Material prim instead would render as a no-op.
        #expect(doc.snapshot.prim(at: self.paint)?.attribute(named: "inputs:metallic") == nil)
    }

    @Test func readsShaderChildValues() throws {
        let doc = shaderBackedDocument()
        #expect(doc.materialInput(try input("roughness"), on: try material(doc, body)) == .double(0.4))
    }

    @Test func clearOnShaderBackedMaterialIsUndoable() throws {
        let doc = shaderBackedDocument()
        let paint = try material(doc, body)
        #expect(doc.clearMaterialInput(try input("roughness"), on: paint))
        #expect(doc.materialInput(try input("roughness"), on: paint) == nil)
        doc.undo()
        #expect(doc.materialInput(try input("roughness"), on: paint) == .double(0.4))
    }
}

@Suite("sRGB transfer")
struct SRGBTransferTests {

    @Test func roundTripsWithinTolerance() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            let back = SRGBTransfer.toLinear(SRGBTransfer.toSRGB(v))
            #expect(abs(back - v) < 1e-9)
        }
    }

    @Test func anchorsMatchTheStandard() {
        #expect(SRGBTransfer.toLinear(0) == 0)
        #expect(abs(SRGBTransfer.toLinear(1) - 1) < 1e-9)
        // Mid-grey sRGB 0.5 is ~0.214 linear — the conversion this exists to get right.
        #expect(abs(SRGBTransfer.toLinear(0.5) - 0.2140) < 1e-3)
    }

    @Test func linearSegmentAppliesNearBlack() {
        // Below the knee the transfer is the linear 12.92× segment.
        #expect(abs(SRGBTransfer.toSRGB(0.002) - 0.02584) < 1e-9)
    }
}
