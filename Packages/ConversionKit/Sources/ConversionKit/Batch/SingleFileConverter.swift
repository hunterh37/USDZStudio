import Foundation
import USDCore

/// Errors surfaced by the shared conversion flow. Distinct cases let the
/// CLI pick usage (2) vs runtime (1) exit codes and let the batch engine
/// record a stable machine-readable reason.
public enum ConversionError: Error, CustomStringConvertible, Sendable {
    /// No importer is registered for the input's extension.
    case unsupportedInput(ext: String, supported: [String])
    /// The pipeline finished without producing an authored stage. In the
    /// standard pipeline this is unreachable, but a custom pipeline could
    /// omit `USDAuthorStage`.
    case noAuthoredStage

    public var description: String {
        switch self {
        case let .unsupportedInput(ext, supported):
            return "unsupported input format .\(ext) (supported: \(supported.joined(separator: ", ")))"
        case .noAuthoredStage:
            return "pipeline produced no stage"
        }
    }
}

/// The product of converting one asset: the serialized USDA text plus
/// everything worth reporting. Writing to disk is the caller's job, which
/// keeps this flow pure and unit-testable without touching the filesystem.
public struct ConversionOutcome: Sendable {
    public var usda: String
    public var log: [String]
    public var diagnostics: [Diagnostic]
    public var triangleCount: Int
    public var materialCount: Int

    public init(
        usda: String,
        log: [String],
        diagnostics: [Diagnostic],
        triangleCount: Int,
        materialCount: Int
    ) {
        self.usda = usda
        self.log = log
        self.diagnostics = diagnostics
        self.triangleCount = triangleCount
        self.materialCount = materialCount
    }
}

/// The single source of truth for "one file in, one USDA out". Both the
/// `convert` CLI subcommand and the batch engine call this so their
/// behavior can never drift.
public enum SingleFileConverter {
    public static func convert(
        input: URL,
        registry: ImporterRegistry = .standard,
        texturePolicy: TexturePolicy = TexturePolicy()
    ) async throws -> ConversionOutcome {
        guard let importer = registry.importer(for: input) else {
            throw ConversionError.unsupportedInput(
                ext: input.pathExtension.lowercased(),
                supported: registry.registeredExtensions
            )
        }

        let imported = try await importer.importAsset(
            at: input,
            options: ImportOptions(maxTextureSize: texturePolicy.maxSize)
        )
        var context = ConversionContext(
            sourceURL: input,
            scene: imported.scene,
            diagnostics: imported.diagnostics
        )
        context.log.append(
            "parse: ok (\(imported.scene.triangleCount) triangles, \(imported.scene.materials.count) materials)"
        )
        context = try await ConversionPipeline.standard(texturePolicy: texturePolicy).run(context)

        guard let stage = context.authoredStage else {
            throw ConversionError.noAuthoredStage
        }

        return ConversionOutcome(
            usda: USDASerializer.serialize(stage),
            log: context.log,
            diagnostics: context.diagnostics,
            triangleCount: imported.scene.triangleCount,
            materialCount: imported.scene.materials.count
        )
    }
}
