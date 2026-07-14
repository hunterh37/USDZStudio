import Foundation
import USDCore

/// Options threaded through every importer (grows through Phase 2).
public struct ImportOptions: Hashable, Sendable {
    public var maxTextureSize: Int?

    public init(maxTextureSize: Int? = nil) {
        self.maxTextureSize = maxTextureSize
    }
}

/// What an importer hands back: the IR plus anything worth telling the user.
public struct ImportResult: Hashable, Sendable {
    public var scene: IntermediateScene
    public var diagnostics: [Diagnostic]

    public init(scene: IntermediateScene, diagnostics: [Diagnostic] = []) {
        self.scene = scene
        self.diagnostics = diagnostics
    }
}

/// Extension point: contributors add importers without touching the app
/// (specs/architecture.md). Importers produce the IntermediateScene IR.
public protocol AssetImporter: Sendable {
    static var supportedExtensions: [String] { get }
    func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult
}

/// Mutable context flowing through pipeline stages
/// (specs/conversion-pipeline.md — Pipeline Model).
public struct ConversionContext: Sendable {
    public var sourceURL: URL
    public var scene: IntermediateScene
    public var diagnostics: [Diagnostic]
    /// Authored USD snapshot, populated by the `usd-author` stage.
    public var authoredStage: StageSnapshot?
    public var log: [String]

    public init(
        sourceURL: URL,
        scene: IntermediateScene = IntermediateScene(),
        diagnostics: [Diagnostic] = [],
        authoredStage: StageSnapshot? = nil,
        log: [String] = []
    ) {
        self.sourceURL = sourceURL
        self.scene = scene
        self.diagnostics = diagnostics
        self.authoredStage = authoredStage
        self.log = log
    }
}

/// One transparent, loggable pipeline step (PRD pillar 3).
public protocol ConversionStage: Sendable {
    var id: String { get }
    func process(_ context: inout ConversionContext) async throws
}

/// Runs stages in order, logging each one — the log shows exactly what
/// happened to the asset (spec principle 1: Transparent).
public struct ConversionPipeline: Sendable {
    public var stages: [any ConversionStage]

    public init(stages: [any ConversionStage]) {
        self.stages = stages
    }

    public func run(_ context: ConversionContext) async throws -> ConversionContext {
        var context = context
        for stage in stages {
            let before = context.diagnostics.count
            do {
                try await stage.process(&context)
            } catch {
                context.log.append("\(stage.id): failed — \(error)")
                throw error
            }
            let emitted = context.diagnostics.count - before
            context.log.append(
                emitted > 0
                    ? "\(stage.id): ok (\(emitted) diagnostic\(emitted == 1 ? "" : "s"))"
                    : "\(stage.id): ok"
            )
        }
        return context
    }
}

/// Registry mapping file extensions to importers.
public struct ImporterRegistry: Sendable {
    private var importersByExtension: [String: any AssetImporter] = [:]

    public init() {}

    public mutating func register(_ importer: any AssetImporter, extensions: [String]) {
        for ext in extensions {
            importersByExtension[ext.lowercased()] = importer
        }
    }

    public func importer(for url: URL) -> (any AssetImporter)? {
        importersByExtension[url.pathExtension.lowercased()]
    }

    public var registeredExtensions: [String] {
        importersByExtension.keys.sorted()
    }
}
