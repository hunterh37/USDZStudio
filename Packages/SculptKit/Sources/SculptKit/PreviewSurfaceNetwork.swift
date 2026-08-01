import USDCore

/// Authors a real `UsdPreviewSurface` shading network for a `MaterialSpec`.
///
/// Before this existed, the material pass wrote texture maps as plain `string`
/// attributes on the surface shader (`inputs:albedoMap`, `inputs:normalMap`, …).
/// Those are not `UsdPreviewSurface` schema inputs, nothing was connected, and
/// no `UsdUVTexture` node was ever created — so every map was inert in our
/// viewport, in QuickLook, in Reality Composer and in every DCC (#171). Colours
/// were authored as `double3` and scalars as `double`, which the schema also
/// rejects.
///
/// This builder emits the shape the schema actually specifies:
///
/// ```
/// def Material "M" {
///     token outputs:surface.connect = </…/M/Surface.outputs:surface>
///     def Shader "Surface" {
///         uniform token info:id = "UsdPreviewSurface"
///         color3f inputs:diffuseColor.connect = </…/M/albedoTexture.outputs:rgb>
///         float   inputs:roughness = 0.22
///         …
///     }
///     def Shader "stReader" { … UsdPrimvarReader_float2, varname = "st" }
///     def Shader "albedoTexture" { … UsdUVTexture, inputs:st.connect = stReader.outputs:result }
/// }
/// ```
///
/// Colour-space handling follows the schema: albedo and emissive maps are
/// `sRGB`, roughness and normal maps are `raw`. Normal maps get the standard
/// `scale`/`bias` remap from [0,1] texture space into [-1,1] tangent space,
/// attenuated by `MaterialSpec.normalScale`.
///
/// Callers that only need to *update* an existing surface shader can take
/// `surfaceAttributes` alone; the texture nodes live in `shaderPrims`.
public enum PreviewSurfaceNetwork {

    /// The `info:id` tokens of the three shader node types this builder emits.
    public static let previewSurfaceID = "UsdPreviewSurface"
    public static let uvTextureID = "UsdUVTexture"
    public static let primvarReaderID = "UsdPrimvarReader_float2"

    /// The primvar the texture nodes read UVs from — matched by the
    /// `primvars:st` that `MeshKit` now authors on generated geometry (#170).
    public static let uvPrimvarName = "st"

    /// The prim name of the shared UV reader inside a material.
    public static let readerName = "stReader"

    /// One authored network, ready to hand to the mutation funnel.
    public struct Build: Sendable, Equatable {
        /// Attributes for the `Material` prim itself (its `outputs:surface`
        /// declaration and the connection into the surface shader).
        public var materialAttributes: [Attribute]
        /// Attributes for the `UsdPreviewSurface` shader child.
        public var surfaceAttributes: [Attribute]
        /// The extra shader prims the network needs: the UV reader and one
        /// `UsdUVTexture` per map. Empty when the material has no textures.
        public var shaderPrims: [Prim]

        public init(materialAttributes: [Attribute], surfaceAttributes: [Attribute],
                    shaderPrims: [Prim]) {
            self.materialAttributes = materialAttributes
            self.surfaceAttributes = surfaceAttributes
            self.shaderPrims = shaderPrims
        }
    }

    /// Which surface input a map drives, and how it must be sampled.
    struct MapChannel {
        /// Shader prim name, e.g. `albedoTexture`.
        let nodeName: String
        /// The `UsdPreviewSurface` input it feeds, e.g. `inputs:diffuseColor`.
        let surfaceInput: String
        /// The USD type of that surface input.
        let surfaceInputType: String
        /// Which texture output to read: `outputs:rgb` for colour/vector maps,
        /// `outputs:r` for single-channel scalar maps.
        let output: String
        /// `sRGB` for colour maps, `raw` for data maps (roughness, normal).
        let colorSpace: String
    }

    static let albedoChannel = MapChannel(
        nodeName: "albedoTexture", surfaceInput: "inputs:diffuseColor",
        surfaceInputType: "color3f", output: "outputs:rgb", colorSpace: "sRGB")
    static let emissiveChannel = MapChannel(
        nodeName: "emissiveTexture", surfaceInput: "inputs:emissiveColor",
        surfaceInputType: "color3f", output: "outputs:rgb", colorSpace: "sRGB")
    static let roughnessChannel = MapChannel(
        nodeName: "roughnessTexture", surfaceInput: "inputs:roughness",
        surfaceInputType: "float", output: "outputs:r", colorSpace: "raw")
    static let normalChannel = MapChannel(
        nodeName: "normalTexture", surfaceInput: "inputs:normal",
        surfaceInputType: "normal3f", output: "outputs:rgb", colorSpace: "raw")

    /// Build the network for `material` living at `materialPath`.
    ///
    /// - Parameters:
    ///   - material: the spec to realise.
    ///   - materialPath: the `Material` prim's path; every connection is
    ///     absolute and rooted here, so the network survives being moved only
    ///     by rebuilding — which is what the material pass does.
    ///   - surfaceName: the surface shader's prim name (the repo authors
    ///     `Surface`).
    public static func build(
        material: MaterialSpec,
        at materialPath: PrimPath,
        surfaceName: String = "Surface"
    ) -> Build {
        let surfacePath = "\(materialPath.description)/\(surfaceName)"

        var surface: [Attribute] = [
            .typed(name: "info:id", type: "token",
                   value: .token(previewSurfaceID), isUniform: true),
        ]
        var shaderPrims: [Prim] = []

        let channels: [(path: String?, channel: MapChannel)] = [
            (material.albedoMap, albedoChannel),
            (material.emissiveMap, emissiveChannel),
            (material.roughnessMap, roughnessChannel),
            (material.normalMap, normalChannel),
        ]
        let usedChannels = channels.compactMap { entry in
            entry.path.map { (path: $0, channel: entry.channel) }
        }

        // Scalar/colour fallbacks are authored for every channel that has no
        // map. A mapped channel gets a connection *instead of* a value: an
        // authored value alongside a connection is ignored by USD, and leaving
        // it in makes the file lie about what renders.
        let mappedInputs = Set(usedChannels.map { $0.channel.surfaceInput })

        if !mappedInputs.contains("inputs:diffuseColor") {
            surface.append(.typed(name: "inputs:diffuseColor", type: "color3f",
                                  value: .vector(material.baseColor)))
        }
        if !mappedInputs.contains("inputs:roughness") {
            surface.append(.typed(name: "inputs:roughness", type: "float",
                                  value: .double(material.roughness)))
        }
        surface.append(.typed(name: "inputs:metallic", type: "float",
                              value: .double(material.metallic)))
        if let emissive = material.emissive, !mappedInputs.contains("inputs:emissiveColor") {
            surface.append(.typed(name: "inputs:emissiveColor", type: "color3f",
                                  value: .vector(emissive)))
        }

        if !usedChannels.isEmpty {
            shaderPrims.append(readerPrim(materialPath: materialPath))
            let readerResult = "\(materialPath.description)/\(readerName).outputs:result"
            for entry in usedChannels {
                let nodePath = "\(materialPath.description)/\(entry.channel.nodeName)"
                shaderPrims.append(texturePrim(
                    material: material, channel: entry.channel,
                    file: entry.path, at: nodePath, stSource: readerResult))
                surface.append(.connected(
                    name: entry.channel.surfaceInput,
                    type: entry.channel.surfaceInputType,
                    to: ["\(nodePath).\(entry.channel.output)"]))
            }
        }

        // The surface's own output, and the material's terminal wired to it.
        surface.append(.connected(name: "outputs:surface", type: "token", to: []))
        let materialAttributes: [Attribute] = [
            .connected(name: "outputs:surface", type: "token",
                       to: ["\(surfacePath).outputs:surface"]),
        ]

        return Build(materialAttributes: materialAttributes,
                     surfaceAttributes: surface,
                     shaderPrims: shaderPrims)
    }

    // MARK: - Nodes

    /// The shared `UsdPrimvarReader_float2` that every texture node samples
    /// `primvars:st` through.
    static func readerPrim(materialPath: PrimPath) -> Prim {
        Prim(
            path: materialPath.appending(readerName) ?? materialPath,
            typeName: "Shader",
            attributes: [
                .typed(name: "info:id", type: "token",
                       value: .token(primvarReaderID), isUniform: true),
                .typed(name: "inputs:varname", type: "token",
                       value: .token(uvPrimvarName)),
                .connected(name: "outputs:result", type: "float2", to: []),
            ])
    }

    /// One `UsdUVTexture` node reading `file`, wired to the shared UV reader.
    static func texturePrim(
        material: MaterialSpec, channel: MapChannel, file: String,
        at nodePath: String, stSource: String
    ) -> Prim {
        var attributes: [Attribute] = [
            .typed(name: "info:id", type: "token",
                   value: .token(uvTextureID), isUniform: true),
            // `asset`, not `string` — a string here does not resolve as a
            // texture reference in any consumer.
            .typed(name: "inputs:file", type: "asset", value: .asset(file)),
            .connected(name: "inputs:st", type: "float2", to: [stSource]),
            .typed(name: "inputs:wrapS", type: "token", value: .token("repeat")),
            .typed(name: "inputs:wrapT", type: "token", value: .token("repeat")),
            .typed(name: "inputs:sourceColorSpace", type: "token",
                   value: .token(channel.colorSpace)),
        ]
        if channel.surfaceInput == normalChannel.surfaceInput {
            // Tangent-space normal maps store [-1,1] packed into [0,1]; the
            // schema's remap is scale (2,2,2,1) / bias (-1,-1,-1,0). Attenuating
            // both by `normalScale` flattens the effect toward the geometric
            // normal without unbalancing the remap.
            let s = max(0, material.normalScale ?? 1)
            attributes.append(.typed(name: "inputs:scale", type: "float4",
                                     value: .vector([2 * s, 2 * s, 2 * s, 1])))
            attributes.append(.typed(name: "inputs:bias", type: "float4",
                                     value: .vector([-s, -s, -s, 0])))
        }
        // Declare both outputs: a consumer may read either, and a declared
        // output is what a connection can legally target.
        attributes.append(.connected(name: "outputs:rgb", type: "float3", to: []))
        attributes.append(.connected(name: "outputs:r", type: "float", to: []))
        return Prim(path: PrimPath(nodePath) ?? PrimPath("/Invalid")!,
                    typeName: "Shader", attributes: attributes)
    }
}
