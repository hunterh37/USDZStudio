import USDCore

// Shader-network validation (#172).
//
// The arkit profile used to report `isCompliant: true, errors: 0` on a stage
// whose `UsdPreviewSurface` network was structurally invalid — unschema'd
// `string` map inputs, `double3` colours, no `UsdUVTexture` nodes at all — and
// on meshes with no UVs for the textures that were nominally bound. `score`
// agreed and returned 1.0. That false green is worse than having no gate: the
// verification loop agents are told to trust actively confirmed a material pass
// that could not render.
//
// These rules close that hole by checking the parts of the UsdShade contract a
// consumer actually depends on: node identity, input names, input types, and
// the presence of the texture coordinates a sampled texture needs.

/// The `UsdPreviewSurface` schema: input name → the set of USD types the schema
/// permits for it. Anything authored on a preview surface that isn't in this
/// table is not a schema input and is ignored by every consumer.
enum PreviewSurfaceSchema {
    static let surfaceID = "UsdPreviewSurface"
    static let uvTextureID = "UsdUVTexture"
    static let primvarReaderPrefix = "UsdPrimvarReader"

    /// Shader `info:id` values we recognise. An unknown id means no renderer
    /// knows how to evaluate the node.
    static let knownShaderIDs: Set<String> = [
        surfaceID, uvTextureID,
        "UsdPrimvarReader_float", "UsdPrimvarReader_float2", "UsdPrimvarReader_float3",
        "UsdPrimvarReader_float4", "UsdPrimvarReader_int", "UsdPrimvarReader_string",
        "UsdPrimvarReader_normal", "UsdPrimvarReader_point", "UsdPrimvarReader_vector",
        "UsdPrimvarReader_matrix", "UsdTransform2d",
    ]

    static let surfaceInputs: [String: Set<String>] = [
        "inputs:diffuseColor": ["color3f"],
        "inputs:emissiveColor": ["color3f"],
        "inputs:specularColor": ["color3f"],
        "inputs:useSpecularWorkflow": ["int"],
        "inputs:metallic": ["float"],
        "inputs:roughness": ["float"],
        "inputs:clearcoat": ["float"],
        "inputs:clearcoatRoughness": ["float"],
        "inputs:opacity": ["float"],
        "inputs:opacityThreshold": ["float"],
        "inputs:ior": ["float"],
        "inputs:normal": ["normal3f"],
        "inputs:displacement": ["float"],
        "inputs:occlusion": ["float"],
    ]

    static let uvTextureInputs: [String: Set<String>] = [
        "inputs:file": ["asset"],
        "inputs:st": ["float2", "texCoord2f"],
        "inputs:wrapS": ["token"],
        "inputs:wrapT": ["token"],
        "inputs:fallback": ["float4"],
        "inputs:scale": ["float4"],
        "inputs:bias": ["float4"],
        "inputs:sourceColorSpace": ["token"],
        "inputs:varname": ["token", "string"],
    ]

    /// The schema table for a shader node, or nil when we don't model that node
    /// type's inputs (primvar readers and transforms vary by suffix).
    static func inputs(forShaderID id: String) -> [String: Set<String>]? {
        switch id {
        case surfaceID: return surfaceInputs
        case uvTextureID: return uvTextureInputs
        default: return nil
        }
    }
}

/// Structural validity of every `Shader` prim on the stage: it must declare a
/// known `info:id`, and each authored `inputs:*` must be a real schema input of
/// that node carrying the schema's type.
///
/// Hard error: a shader failing these does not render as authored anywhere — the
/// exact failure mode #171 produced and this rule was blind to.
public struct ShaderGraphRule: ValidationRule {
    public let id = "shader.graph"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims().filter { $0.typeName == "Shader" }.flatMap(evaluate(shader:))
    }

    private func evaluate(shader: Prim) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        func flag(_ message: String) {
            diagnostics.append(Diagnostic(
                ruleID: id, severity: severity,
                message: "\(shader.name): \(message)", primPath: shader.path))
        }

        guard let shaderID = Self.shaderID(shader) else {
            flag("Shader has no info:id; no renderer can evaluate it.")
            return diagnostics
        }
        guard PreviewSurfaceSchema.knownShaderIDs.contains(shaderID) else {
            flag("unknown shader info:id '\(shaderID)'.")
            return diagnostics
        }
        guard let schema = PreviewSurfaceSchema.inputs(forShaderID: shaderID) else {
            return diagnostics
        }

        for attribute in shader.attributes where attribute.name.hasPrefix("inputs:") {
            guard let allowed = schema[attribute.name] else {
                flag("'\(attribute.name)' is not a \(shaderID) input; it is ignored by every consumer. "
                     + "Texture maps must be authored as UsdUVTexture nodes connected to a schema input.")
                continue
            }
            // A connection satisfies the input without a value; the declared
            // type still has to match.
            guard let declared = attribute.declaredType else { continue }
            if !allowed.contains(declared) {
                flag("'\(attribute.name)' is typed \(declared) but \(shaderID) declares "
                     + "\(allowed.sorted().joined(separator: " or ")).")
            }
        }
        return diagnostics
    }

    static func shaderID(_ prim: Prim) -> String? {
        if case .token(let id)? = prim.attribute(named: "info:id")?.value { return id }
        if case .string(let id)? = prim.attribute(named: "info:id")?.value { return id }
        return nil
    }
}

/// A `UsdUVTexture` must actually be able to sample: it needs a `file`, and its
/// `st` input must be wired to something (in practice a
/// `UsdPrimvarReader_float2`). An unwired texture samples the fallback colour
/// everywhere, which reads as flat colour — indistinguishable, to an agent
/// reading a render, from "the map didn't work".
public struct TextureWiringRule: ValidationRule {
    public let id = "shader.textureWiring"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims()
            .filter { ShaderGraphRule.shaderID($0) == PreviewSurfaceSchema.uvTextureID }
            .flatMap(evaluate(texture:))
    }

    private func evaluate(texture: Prim) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        func flag(_ message: String) {
            diagnostics.append(Diagnostic(
                ruleID: id, severity: severity,
                message: "\(texture.name): \(message)", primPath: texture.path))
        }
        let file = texture.attribute(named: "inputs:file")
        switch file?.value {
        case .asset(let path) where !path.isEmpty:
            break
        case .none:
            flag("UsdUVTexture has no inputs:file; it samples nothing.")
        case .some(let value):
            flag("inputs:file is \(value.typeLabel), not an asset path; it will not resolve.")
        }
        let st = texture.attribute(named: "inputs:st")
        if st == nil || st!.connections.isEmpty {
            flag("inputs:st is not connected to a UV reader; the texture samples a "
                 + "constant coordinate and renders as flat colour.")
        }
        return diagnostics
    }
}

/// A mesh bound to a material whose network samples textures must carry the UV
/// primvar those textures read.
///
/// This is the mesh-side half of the same failure: the shader graph can be
/// perfect and still render flat, because the geometry has no `primvars:st` to
/// map through (#170). Reported as an error, since the authored intent
/// (a texture map) provably cannot be honoured.
public struct MissingUVRule: ValidationRule {
    public let id = "mesh.missingUVs"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        let texturedMaterials = Self.texturedMaterialPaths(in: stage)
        guard !texturedMaterials.isEmpty else { return [] }
        return stage.allPrims()
            .filter { prim in
                prim.typeName == "Mesh"
                    && MeshTopologyRule.pointCount(prim) > 0
                    && !Self.hasUVs(prim)
                    && Self.boundMaterials(of: prim).contains(where: texturedMaterials.contains)
            }
            .map { prim in
                Diagnostic(
                    ruleID: id, severity: severity,
                    message: "\(prim.name): bound to a material with texture maps but has no "
                        + "primvars:st; every texture on it is unrenderable.",
                    primPath: prim.path)
            }
    }

    /// Paths of materials whose subtree contains at least one `UsdUVTexture`.
    static func texturedMaterialPaths(in stage: any USDStageProtocol) -> Set<PrimPath> {
        var paths: Set<PrimPath> = []
        for prim in stage.allPrims() where prim.typeName == "Material" {
            if prim.flattened().contains(where: {
                ShaderGraphRule.shaderID($0) == PreviewSurfaceSchema.uvTextureID
            }) {
                paths.insert(prim.path)
            }
        }
        return paths
    }

    /// Every material path this prim binds, directly or via a purpose-specific
    /// binding.
    static func boundMaterials(of prim: Prim) -> [PrimPath] {
        prim.relationships
            .filter { $0.name == "material:binding" || $0.name.hasPrefix("material:binding:") }
            .flatMap(\.targets)
    }

    /// `true` when the mesh carries any UV primvar (`st` by convention, but a
    /// reader can name another, so any `primvars:*st*` set counts).
    static func hasUVs(_ prim: Prim) -> Bool {
        prim.attributes.contains { attribute in
            guard attribute.name.hasPrefix("primvars:") else { return false }
            let name = String(attribute.name.dropFirst("primvars:".count))
            return name == "st" || name.hasSuffix("_st") || name.hasSuffix(":st")
                || attribute.declaredType == "texCoord2f[]"
        }
    }
}
