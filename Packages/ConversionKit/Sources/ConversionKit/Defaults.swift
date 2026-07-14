import Foundation

extension ImporterRegistry {
    /// Every built-in importer, keyed by its extensions. The conversion
    /// sheet, batch engine, and CLI all start from this.
    public static var standard: ImporterRegistry {
        var registry = ImporterRegistry()
        registry.register(GLTFImporter(), extensions: GLTFImporter.supportedExtensions)
        registry.register(ModelIOImporter(), extensions: ModelIOImporter.supportedExtensions)
        return registry
    }
}

extension ConversionPipeline {
    /// The standard post-import stage sequence
    /// (specs/conversion-pipeline.md) as implemented so far:
    /// sanitize-names → textures → usd-author.
    public static func standard(texturePolicy: TexturePolicy = TexturePolicy()) -> ConversionPipeline {
        ConversionPipeline(stages: [
            SanitizeNamesStage(),
            TexturePipelineStage(policy: texturePolicy),
            USDAuthorStage(),
        ])
    }
}
