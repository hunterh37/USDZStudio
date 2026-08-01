import Testing
import USDCore
@testable import SculptKit

/// #171: the material pass wrote texture maps as plain `string` attributes on
/// the surface shader — not schema inputs, nothing connected, no `UsdUVTexture`
/// nodes — so every map was inert in every consumer, and colours/scalars were
/// mis-typed as `double3`/`double`. These pin the network the builder now emits.
@Suite("PreviewSurfaceNetwork")
struct PreviewSurfaceNetworkTests {

    static let path = PrimPath("/Looks/M")!

    static func spec(
        albedo: String? = nil, normal: String? = nil,
        roughness: String? = nil, emissive: String? = nil,
        normalScale: Double? = nil, emissiveColor: [Double]? = nil
    ) -> MaterialSpec {
        MaterialSpec(id: "M", baseColor: [0.055, 0.4, 0.105], roughness: 0.22, metallic: 0.6,
                     emissive: emissiveColor, albedoMap: albedo, normalMap: normal,
                     roughnessMap: roughness, emissiveMap: emissive, normalScale: normalScale)
    }

    static func surfaceAttribute(_ build: PreviewSurfaceNetwork.Build, _ name: String) -> Attribute? {
        build.surfaceAttributes.first { $0.name == name }
    }

    static func shader(_ build: PreviewSurfaceNetwork.Build, named name: String) -> Prim? {
        build.shaderPrims.first { $0.path.name == name }
    }

    // MARK: - Untextured materials

    /// The plain case must still be correctly *typed*: `color3f`/`float`, not the
    /// wire-inferred `double3`/`double` the schema rejects.
    @Test func untexturedMaterialAuthorsSchemaTypedValues() throws {
        let build = PreviewSurfaceNetwork.build(material: Self.spec(), at: Self.path)
        #expect(build.shaderPrims.isEmpty)   // no maps → no texture nodes

        let info = try #require(Self.surfaceAttribute(build, "info:id"))
        #expect(info.value == .token("UsdPreviewSurface"))
        #expect(info.isUniform)

        let diffuse = try #require(Self.surfaceAttribute(build, "inputs:diffuseColor"))
        #expect(diffuse.declaredType == "color3f")
        #expect(diffuse.value == .vector([0.055, 0.4, 0.105]))

        #expect(Self.surfaceAttribute(build, "inputs:roughness")?.declaredType == "float")
        #expect(Self.surfaceAttribute(build, "inputs:metallic")?.declaredType == "float")
    }

    @Test func emissiveColourIsAuthoredOnlyWhenPresent() {
        let without = PreviewSurfaceNetwork.build(material: Self.spec(), at: Self.path)
        #expect(Self.surfaceAttribute(without, "inputs:emissiveColor") == nil)

        let with = PreviewSurfaceNetwork.build(
            material: Self.spec(emissiveColor: [1, 0.5, 0]), at: Self.path)
        #expect(Self.surfaceAttribute(with, "inputs:emissiveColor")?.declaredType == "color3f")
    }

    /// The material's terminal must be wired to the surface, or nothing
    /// downstream can find the surface at all.
    @Test func materialTerminalIsWiredToTheSurface() throws {
        let build = PreviewSurfaceNetwork.build(material: Self.spec(), at: Self.path)
        let terminal = try #require(build.materialAttributes.first { $0.name == "outputs:surface" })
        #expect(terminal.declaredType == "token")
        #expect(terminal.connections == ["/Looks/M/Surface.outputs:surface"])
        // And the surface declares the output that terminal points at.
        #expect(Self.surfaceAttribute(build, "outputs:surface")?.value.isUnauthored == true)
    }

    // MARK: - Textured materials

    @Test func eachMapBecomesAConnectedUVTextureNode() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(albedo: "/t/a.png", normal: "/t/n.png",
                                roughness: "/t/r.png", emissive: "/t/e.png"),
            at: Self.path)

        // One shared reader plus one node per map.
        #expect(build.shaderPrims.count == 5)
        let reader = try #require(Self.shader(build, named: "stReader"))
        #expect(reader.attribute(named: "info:id")?.value == .token("UsdPrimvarReader_float2"))
        // The primvar name must match what MeshKit authors on the geometry.
        #expect(reader.attribute(named: "inputs:varname")?.value
                == .token(PreviewSurfaceNetwork.uvPrimvarName))

        let expected: [(node: String, file: String, input: String, type: String, output: String)] = [
            ("albedoTexture", "/t/a.png", "inputs:diffuseColor", "color3f", "outputs:rgb"),
            ("emissiveTexture", "/t/e.png", "inputs:emissiveColor", "color3f", "outputs:rgb"),
            // Single-channel: reads the red output, not rgb.
            ("roughnessTexture", "/t/r.png", "inputs:roughness", "float", "outputs:r"),
            ("normalTexture", "/t/n.png", "inputs:normal", "normal3f", "outputs:rgb"),
        ]
        for case let (node, file, input, type, output) in expected {
            let texture = try #require(Self.shader(build, named: node))
            #expect(texture.typeName == "Shader")
            #expect(texture.attribute(named: "info:id")?.value == .token("UsdUVTexture"))
            // `asset`, not `string` — a string here resolves in no consumer.
            let fileInput = try #require(texture.attribute(named: "inputs:file"))
            #expect(fileInput.declaredType == "asset")
            #expect(fileInput.value == .asset(file))
            #expect(texture.attribute(named: "inputs:st")?.connections
                    == ["/Looks/M/stReader.outputs:result"])

            let surfaceInput = try #require(Self.surfaceAttribute(build, input))
            #expect(surfaceInput.declaredType == type)
            #expect(surfaceInput.connections == ["/Looks/M/\(node).\(output)"])
        }
    }

    /// Colour maps are sRGB; data maps (roughness, normal) are raw. Getting this
    /// backwards double-applies a gamma curve to the data.
    @Test func colourSpaceFollowsTheChannelKind() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(albedo: "/t/a.png", normal: "/t/n.png",
                                roughness: "/t/r.png", emissive: "/t/e.png"),
            at: Self.path)
        let expected = ["albedoTexture": "sRGB", "emissiveTexture": "sRGB",
                        "roughnessTexture": "raw", "normalTexture": "raw"]
        for (node, space) in expected {
            let texture = try #require(Self.shader(build, named: node))
            #expect(texture.attribute(named: "inputs:sourceColorSpace")?.value == .token(space),
                    "\(node) should sample as \(space)")
        }
    }

    /// A mapped channel gets a connection *instead of* a value. USD ignores an
    /// authored value alongside a connection, so leaving one in makes the file
    /// lie about what actually renders.
    @Test func mappedChannelsCarryNoCompetingValue() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(albedo: "/t/a.png", roughness: "/t/r.png"), at: Self.path)
        let diffuse = try #require(Self.surfaceAttribute(build, "inputs:diffuseColor"))
        #expect(diffuse.value.isUnauthored)
        #expect(Self.surfaceAttribute(build, "inputs:roughness")?.value.isUnauthored == true)
        // Unmapped channels keep their scalar value.
        #expect(Self.surfaceAttribute(build, "inputs:metallic")?.value == .double(0.6))
    }

    // MARK: - Normal-map remap

    /// Tangent-space normal maps pack [-1,1] into [0,1]; the schema's remap is
    /// scale (2,2,2,1) / bias (-1,-1,-1,0), attenuated by `normalScale`.
    @Test func normalMapCarriesTheTangentSpaceRemap() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(normal: "/t/n.png", normalScale: 1), at: Self.path)
        let node = try #require(Self.shader(build, named: "normalTexture"))
        #expect(node.attribute(named: "inputs:scale")?.value == .vector([2, 2, 2, 1]))
        #expect(node.attribute(named: "inputs:bias")?.value == .vector([-1, -1, -1, 0]))
    }

    @Test func normalScaleAttenuatesTheRemapSymmetrically() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(normal: "/t/n.png", normalScale: 0.5), at: Self.path)
        let node = try #require(Self.shader(build, named: "normalTexture"))
        #expect(node.attribute(named: "inputs:scale")?.value == .vector([1, 1, 1, 1]))
        #expect(node.attribute(named: "inputs:bias")?.value == .vector([-0.5, -0.5, -0.5, 0]))
    }

    @Test func absentNormalScaleDefaultsToFullStrength() throws {
        let build = PreviewSurfaceNetwork.build(material: Self.spec(normal: "/t/n.png"), at: Self.path)
        let node = try #require(Self.shader(build, named: "normalTexture"))
        #expect(node.attribute(named: "inputs:scale")?.value == .vector([2, 2, 2, 1]))
    }

    /// A negative scale would invert the remap; it is floored at zero (flat).
    @Test func negativeNormalScaleIsFlooredAtZero() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(normal: "/t/n.png", normalScale: -3), at: Self.path)
        let node = try #require(Self.shader(build, named: "normalTexture"))
        #expect(node.attribute(named: "inputs:scale")?.value == .vector([0, 0, 0, 1]))
        #expect(node.attribute(named: "inputs:bias")?.value == .vector([0, 0, 0, 0]))
    }

    // MARK: - Serialization

    /// End to end: the built network must serialize to `.usda` text that carries
    /// the nodes and the connections. This is the shape #171 said was missing
    /// from every written file.
    @Test func networkSerializesWithConnectionsIntact() {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(albedo: "/t/a.png"), at: Self.path)
        let surface = Prim(path: PrimPath("/Looks/M/Surface")!, typeName: "Shader",
                           attributes: build.surfaceAttributes)
        let material = Prim(path: Self.path, typeName: "Material",
                            attributes: build.materialAttributes,
                            children: [surface] + build.shaderPrims)
        let text = USDASerializer.serialize(
            StageSnapshot(rootPrims: [Prim(path: PrimPath("/Looks")!, typeName: "Scope",
                                           children: [material])]))
        #expect(text.contains("uniform token info:id = \"UsdUVTexture\""))
        #expect(text.contains("asset inputs:file = @/t/a.png@"))
        #expect(text.contains("color3f inputs:diffuseColor.connect = </Looks/M/albedoTexture.outputs:rgb>"))
        #expect(text.contains("token outputs:surface.connect = </Looks/M/Surface.outputs:surface>"))
        // Not a single unschema'd pseudo-input survives.
        #expect(!text.contains("albedoMap"))
    }

    @Test func surfaceNameIsHonoured() throws {
        let build = PreviewSurfaceNetwork.build(
            material: Self.spec(), at: Self.path, surfaceName: "PreviewSurface")
        let terminal = try #require(build.materialAttributes.first { $0.name == "outputs:surface" })
        #expect(terminal.connections == ["/Looks/M/PreviewSurface.outputs:surface"])
    }
}
