import Foundation
import USDCore

/// Options threaded through every importer (grows in Phase 2).
public struct ImportOptions: Hashable, Sendable {
    public var maxTextureSize: Int?

    public init(maxTextureSize: Int? = nil) {
        self.maxTextureSize = maxTextureSize
    }
}

/// Extension point: contributors add importers without touching the app
/// (specs/architecture.md). Concrete importers land in Phase 2.
public protocol AssetImporter: Sendable {
    static var supportedExtensions: [String] { get }
    func importAsset(at url: URL, options: ImportOptions) async throws -> StageSnapshot
}

/// Mutable context flowing through pipeline stages.
public struct ConversionContext: Sendable {
    public var sourceURL: URL
    public var stage: StageSnapshot
    public var log: [String]

    public init(sourceURL: URL, stage: StageSnapshot = StageSnapshot(), log: [String] = []) {
        self.sourceURL = sourceURL
        self.stage = stage
        self.log = log
    }
}

/// One transparent, loggable pipeline step (PRD pillar 3).
public protocol ConversionStage: Sendable {
    var id: String { get }
    func process(_ context: inout ConversionContext) async throws
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
