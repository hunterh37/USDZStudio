import Testing
import USDCore
@testable import ValidationKit

/// #172: `validate --profile arkit` reported `isCompliant: true, errors: 0` on a
/// stage whose `UsdPreviewSurface` network was structurally invalid — `string`
/// map inputs, `double3` colours, no `UsdUVTexture` nodes — and on meshes with
/// no UVs for textures that were nominally bound. `score` agreed and returned
/// 1.0. These lock the gate onto the real contract.
@Suite("Shader-network rules")
struct ShaderRuleTests {

    // MARK: - Builders

    static func stage(_ prims: [Prim], defaultPrim: String? = "Root") -> StageSnapshot {
        StageSnapshot(metadata: StageMetadata(defaultPrim: defaultPrim), rootPrims: prims)
    }

    static func shader(_ name: String, id: String?, attributes: [Attribute] = []) -> Prim {
        var all = attributes
        if let id {
            all.insert(.typed(name: "info:id", type: "token", value: .token(id), isUniform: true),
                       at: 0)
        }
        return Prim(path: PrimPath("/Looks/M/\(name)")!, typeName: "Shader", attributes: all)
    }

    static func looks(_ shaders: [Prim], materialAttributes: [Attribute] = []) -> Prim {
        Prim(path: PrimPath("/Looks")!, typeName: "Scope",
             children: [Prim(path: PrimPath("/Looks/M")!, typeName: "Material",
                             attributes: materialAttributes, children: shaders)])
    }

    /// A mesh with topology, optionally UVs, optionally bound to `/Looks/M`.
    static func mesh(uvs: Bool, bound: Bool = true) -> Prim {
        var attributes: [Attribute] = [
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1])),
            Attribute(name: "faceVertexCounts", value: .intArray([4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
        ]
        if uvs {
            attributes.append(Attribute(
                name: "primvars:st", value: .doubleArray([0, 0, 1, 0, 1, 1, 0, 1]),
                declaredType: "texCoord2f[]"))
        }
        return Prim(
            path: PrimPath("/Root/Geom")!, typeName: "Mesh", attributes: attributes,
            relationships: bound
                ? [Relationship(name: "material:binding", targets: [PrimPath("/Looks/M")!])]
                : [])
    }

    static func root(_ mesh: Prim) -> Prim {
        Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    }

    /// The exact broken surface from the issue: unschema'd `string` map inputs
    /// and `double3`/`double` scalars, no texture nodes at all.
    static func brokenSurface() -> Prim {
        shader("Surface", id: "UsdPreviewSurface", attributes: [
            Attribute(name: "inputs:diffuseColor", value: .vector([0.055, 0.4, 0.105]),
                      declaredType: "double3"),
            Attribute(name: "inputs:roughness", value: .double(0.22), declaredType: "double"),
            Attribute(name: "inputs:albedoMap", value: .string("/t/marble_albedo.png"),
                      declaredType: "string"),
            Attribute(name: "inputs:normalMap", value: .string("/t/marble_normal.png"),
                      declaredType: "string"),
        ])
    }

    static func validSurface() -> Prim {
        shader("Surface", id: "UsdPreviewSurface", attributes: [
            .typed(name: "inputs:diffuseColor", type: "color3f", value: .vector([0.5, 0.5, 0.5])),
            .typed(name: "inputs:roughness", type: "float", value: .double(0.4)),
        ])
    }

    static func validTexture(_ name: String = "albedoTexture") -> Prim {
        shader(name, id: "UsdUVTexture", attributes: [
            .typed(name: "inputs:file", type: "asset", value: .asset("/t/a.png")),
            .connected(name: "inputs:st", type: "float2", to: ["/Looks/M/stReader.outputs:result"]),
        ])
    }

    // MARK: - ShaderGraphRule

    /// The headline regression: the broken network from the issue must now
    /// produce hard errors, and the arkit profile must refuse to call it clean.
    @Test func theIssuesBrokenNetworkIsNoLongerFalseGreen() {
        let snapshot = Self.stage([
            Self.root(Self.mesh(uvs: false)),
            Self.looks([Self.brokenSurface()]),
        ])
        let report = ValidationEngine.arkitProfile.validate(snapshot)
        #expect(report.errorCount > 0)
        #expect(report.isCompliant == false)
        // And it names the specific offences, not just "something is wrong".
        let messages = report.diagnostics.map(\.message).joined(separator: "\n")
        #expect(messages.contains("inputs:albedoMap"))
        #expect(messages.contains("double3"))
    }

    @Test func unschemaInputIsFlagged() {
        let diagnostics = ShaderGraphRule().evaluate(
            stage: Self.stage([Self.looks([Self.brokenSurface()])]))
        let names = diagnostics.map(\.message).joined()
        #expect(names.contains("inputs:albedoMap"))
        #expect(names.contains("inputs:normalMap"))
        #expect(diagnostics.allSatisfy { $0.severity == .error })
    }

    @Test func mistypedInputIsFlagged() {
        let surface = Self.shader("Surface", id: "UsdPreviewSurface", attributes: [
            Attribute(name: "inputs:diffuseColor", value: .vector([1, 0, 0]), declaredType: "double3"),
            Attribute(name: "inputs:metallic", value: .double(1), declaredType: "double"),
        ])
        let messages = ShaderGraphRule()
            .evaluate(stage: Self.stage([Self.looks([surface])]))
            .map(\.message).joined(separator: "\n")
        #expect(messages.contains("color3f"))
        #expect(messages.contains("float"))
    }

    @Test func correctlyTypedSurfaceIsClean() {
        #expect(ShaderGraphRule()
            .evaluate(stage: Self.stage([Self.looks([Self.validSurface()])])).isEmpty)
    }

    @Test func shaderWithNoInfoIDIsFlagged() {
        let diagnostics = ShaderGraphRule().evaluate(
            stage: Self.stage([Self.looks([Self.shader("Mystery", id: nil)])]))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("no info:id"))
    }

    @Test func unknownShaderIDIsFlagged() {
        let diagnostics = ShaderGraphRule().evaluate(
            stage: Self.stage([Self.looks([Self.shader("X", id: "MyCustomSurface")])]))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("MyCustomSurface"))
    }

    /// A connected input carries no value, only a declared type — that must
    /// satisfy the rule rather than trip it.
    @Test func connectedInputSatisfiesTheSchema() {
        let surface = Self.shader("Surface", id: "UsdPreviewSurface", attributes: [
            .connected(name: "inputs:diffuseColor", type: "color3f",
                       to: ["/Looks/M/albedoTexture.outputs:rgb"]),
        ])
        #expect(ShaderGraphRule().evaluate(stage: Self.stage([Self.looks([surface])])).isEmpty)
    }

    /// Node types whose inputs we don't model (primvar readers vary by suffix)
    /// are accepted rather than falsely flagged.
    @Test func unmodelledButKnownNodeTypesAreAccepted() {
        let reader = Self.shader("stReader", id: "UsdPrimvarReader_float2", attributes: [
            .typed(name: "inputs:varname", type: "token", value: .token("st")),
        ])
        #expect(ShaderGraphRule().evaluate(stage: Self.stage([Self.looks([reader])])).isEmpty)
    }

    /// An `info:id` authored as a `string` rather than a `token` is still read,
    /// so a file from another tool isn't reported as having no id at all.
    @Test func stringTypedInfoIDIsStillRead() {
        let surface = Prim(
            path: PrimPath("/Looks/M/Surface")!, typeName: "Shader",
            attributes: [Attribute(name: "info:id", value: .string("UsdPreviewSurface"))])
        #expect(ShaderGraphRule().evaluate(stage: Self.stage([Self.looks([surface])])).isEmpty)
    }

    /// An input with no declared type can't be type-checked; it must not be
    /// flagged on a guess.
    @Test func undeclaredTypeIsNotTypeChecked() {
        let surface = Self.shader("Surface", id: "UsdPreviewSurface", attributes: [
            Attribute(name: "inputs:roughness", value: .double(0.5)),
        ])
        #expect(ShaderGraphRule().evaluate(stage: Self.stage([Self.looks([surface])])).isEmpty)
    }

    // MARK: - TextureWiringRule

    @Test func textureWithNoFileIsFlagged() {
        let texture = Self.shader("albedoTexture", id: "UsdUVTexture", attributes: [
            .connected(name: "inputs:st", type: "float2", to: ["/Looks/M/stReader.outputs:result"]),
        ])
        let diagnostics = TextureWiringRule().evaluate(stage: Self.stage([Self.looks([texture])]))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("no inputs:file"))
    }

    /// The #171 shape: a file path authored as a `string` rather than an `asset`
    /// does not resolve as a texture reference in any consumer.
    @Test func stringTypedFileIsFlagged() {
        let texture = Self.shader("albedoTexture", id: "UsdUVTexture", attributes: [
            Attribute(name: "inputs:file", value: .string("/t/a.png"), declaredType: "string"),
            .connected(name: "inputs:st", type: "float2", to: ["/Looks/M/stReader.outputs:result"]),
        ])
        let messages = TextureWiringRule()
            .evaluate(stage: Self.stage([Self.looks([texture])])).map(\.message).joined()
        #expect(messages.contains("not an asset path"))
    }

    @Test func emptyFilePathIsFlagged() {
        let texture = Self.shader("albedoTexture", id: "UsdUVTexture", attributes: [
            .typed(name: "inputs:file", type: "asset", value: .asset("")),
            .connected(name: "inputs:st", type: "float2", to: ["/Looks/M/stReader.outputs:result"]),
        ])
        #expect(TextureWiringRule().evaluate(stage: Self.stage([Self.looks([texture])])).count == 1)
    }

    /// An unwired `st` samples a constant coordinate, so the texture renders as
    /// flat colour — indistinguishable, from a render, from "the map failed".
    @Test func unwiredSTIsFlagged() {
        let texture = Self.shader("albedoTexture", id: "UsdUVTexture", attributes: [
            .typed(name: "inputs:file", type: "asset", value: .asset("/t/a.png")),
        ])
        let messages = TextureWiringRule()
            .evaluate(stage: Self.stage([Self.looks([texture])])).map(\.message).joined()
        #expect(messages.contains("not connected"))
    }

    @Test func fullyWiredTextureIsClean() {
        #expect(TextureWiringRule()
            .evaluate(stage: Self.stage([Self.looks([Self.validTexture()])])).isEmpty)
    }

    @Test func nonTextureShadersAreIgnored() {
        #expect(TextureWiringRule()
            .evaluate(stage: Self.stage([Self.looks([Self.validSurface()])])).isEmpty)
    }

    // MARK: - MissingUVRule

    /// The mesh-side half of the same failure (#170): a perfect shader graph
    /// still renders flat when the geometry has no `primvars:st`.
    @Test func texturedMaterialOnUVLessMeshIsFlagged() {
        let snapshot = Self.stage([
            Self.root(Self.mesh(uvs: false)),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        let diagnostics = MissingUVRule().evaluate(stage: snapshot)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].message.contains("primvars:st"))
    }

    @Test func meshWithUVsIsClean() {
        let snapshot = Self.stage([
            Self.root(Self.mesh(uvs: true)),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    /// No texture in the network means no UVs are needed — an untextured mesh
    /// must not be nagged about coordinates nothing reads.
    @Test func untexturedMaterialNeedsNoUVs() {
        let snapshot = Self.stage([
            Self.root(Self.mesh(uvs: false)),
            Self.looks([Self.validSurface()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    @Test func unboundMeshIsNotFlagged() {
        let snapshot = Self.stage([
            Self.root(Self.mesh(uvs: false, bound: false)),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    /// A mesh bound to a *different*, untextured material must not inherit
    /// another material's texture requirement.
    @Test func bindingToAnUntexturedMaterialIsClean() {
        let other = Prim(path: PrimPath("/Looks2")!, typeName: "Scope",
                         children: [Prim(path: PrimPath("/Looks2/Plain")!, typeName: "Material")])
        var mesh = Self.mesh(uvs: false, bound: false)
        mesh.relationships = [Relationship(name: "material:binding",
                                           targets: [PrimPath("/Looks2/Plain")!])]
        let snapshot = Self.stage([
            Self.root(mesh), other,
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    /// Purpose-specific bindings (`material:binding:preview`) count too.
    @Test func purposeSpecificBindingIsHonoured() {
        var mesh = Self.mesh(uvs: false, bound: false)
        mesh.relationships = [Relationship(name: "material:binding:preview",
                                           targets: [PrimPath("/Looks/M")!])]
        let snapshot = Self.stage([
            Self.root(mesh),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).count == 1)
    }

    /// An empty mesh contributes nothing, so it isn't the UV rule's problem
    /// (`EmptyMeshRule` already reports it).
    @Test func emptyMeshIsNotFlagged() {
        let empty = Prim(
            path: PrimPath("/Root/Geom")!, typeName: "Mesh",
            relationships: [Relationship(name: "material:binding", targets: [PrimPath("/Looks/M")!])])
        let snapshot = Self.stage([
            Self.root(empty),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    /// A UV set under a non-conventional primvar name still counts when it is
    /// typed as texture coordinates — a reader can name whichever it likes.
    @Test func alternativelyNamedUVSetCounts() {
        var mesh = Self.mesh(uvs: false)
        mesh.attributes.append(Attribute(
            name: "primvars:map1", value: .doubleArray([0, 0, 1, 0, 1, 1, 0, 1]),
            declaredType: "texCoord2f[]"))
        let snapshot = Self.stage([
            Self.root(mesh),
            Self.looks([Self.validSurface(), Self.validTexture()]),
        ])
        #expect(MissingUVRule().evaluate(stage: snapshot).isEmpty)
    }

    // MARK: - A correct stage is still green

    /// The counterweight: a properly authored textured stage must pass cleanly,
    /// or the new rules would just replace false green with false red.
    @Test func aCorrectTexturedStageIsFullyCompliant() {
        let reader = Self.shader("stReader", id: "UsdPrimvarReader_float2", attributes: [
            .typed(name: "inputs:varname", type: "token", value: .token("st")),
        ])
        var mesh = Self.mesh(uvs: true)
        mesh.attributes.append(Attribute(name: "normals", value: .float3Array(
            Array(repeating: 0, count: 12))))
        mesh.attributes.append(Attribute(name: "subdivisionScheme", value: .token("none"),
                                         isUniform: true))
        let surface = Self.shader("Surface", id: "UsdPreviewSurface", attributes: [
            .connected(name: "inputs:diffuseColor", type: "color3f",
                       to: ["/Looks/M/albedoTexture.outputs:rgb"]),
            .typed(name: "inputs:roughness", type: "float", value: .double(0.4)),
        ])
        let snapshot = Self.stage([
            Self.root(mesh),
            Self.looks([surface, reader, Self.validTexture()]),
        ])
        let report = ValidationEngine.arkitProfile.validate(snapshot)
        #expect(report.errorCount == 0)
        #expect(report.isCompliant)
    }
}
