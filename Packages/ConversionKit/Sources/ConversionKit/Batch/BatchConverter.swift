import Foundation
import USDCore

/// One input→output conversion request in a batch.
public struct BatchJob: Hashable, Sendable {
    public var input: URL
    public var output: URL

    public init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }
}

/// Outcome of a single job. `skipped` is reserved for jobs the engine
/// declined to run (e.g. output already exists and overwrite is off).
public enum BatchItemStatus: String, Sendable, Codable {
    case succeeded
    case failed
    case skipped
}

/// A machine-readable record for one job — the row in a CSV/JSON report.
public struct BatchItemResult: Sendable, Codable, Hashable {
    public var input: String
    public var output: String
    public var status: BatchItemStatus
    public var triangleCount: Int
    public var materialCount: Int
    public var warningCount: Int
    public var errorCount: Int
    /// Failure reason, or `nil` on success.
    public var message: String?
    public var durationSeconds: Double

    public init(
        input: String,
        output: String,
        status: BatchItemStatus,
        triangleCount: Int = 0,
        materialCount: Int = 0,
        warningCount: Int = 0,
        errorCount: Int = 0,
        message: String? = nil,
        durationSeconds: Double = 0
    ) {
        self.input = input
        self.output = output
        self.status = status
        self.triangleCount = triangleCount
        self.materialCount = materialCount
        self.warningCount = warningCount
        self.errorCount = errorCount
        self.message = message
        self.durationSeconds = durationSeconds
    }
}

/// Aggregate report for a batch run. Codable so `--report out.json`
/// serializes it directly; `csv` renders the pipeline-friendly table.
public struct BatchReport: Sendable, Codable, Hashable {
    public var items: [BatchItemResult]

    public init(items: [BatchItemResult]) {
        self.items = items
    }

    public var succeededCount: Int { items.filter { $0.status == .succeeded }.count }
    public var failedCount: Int { items.filter { $0.status == .failed }.count }
    public var skippedCount: Int { items.filter { $0.status == .skipped }.count }

    /// A batch "fails" (nonzero CLI exit) if any job failed.
    public var hasFailures: Bool { failedCount > 0 }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// RFC-4180 CSV: quotes fields, doubles embedded quotes.
    public var csv: String {
        let header = ["input", "output", "status", "triangles", "materials", "warnings", "errors", "seconds", "message"]
        var rows = [header.map(Self.escape).joined(separator: ",")]
        for item in items {
            let fields = [
                item.input,
                item.output,
                item.status.rawValue,
                String(item.triangleCount),
                String(item.materialCount),
                String(item.warningCount),
                String(item.errorCount),
                String(format: "%.3f", item.durationSeconds),
                item.message ?? "",
            ]
            rows.append(fields.map(Self.escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Runs many `BatchJob`s sequentially, never throwing: a failed job becomes
/// a `failed` row so one bad asset can't abort a nightly pipeline run.
/// Filesystem writes go through injectable closures so the engine is fully
/// unit-testable without a real disk.
public struct BatchConverter: Sendable {
    public var registry: ImporterRegistry
    public var texturePolicy: TexturePolicy
    /// If false, a job whose output already exists is reported `skipped`.
    public var overwrite: Bool

    private let fileExists: @Sendable (URL) -> Bool
    private let writeFile: @Sendable (String, URL) throws -> Void
    private let now: @Sendable () -> Date

    public init(
        registry: ImporterRegistry = .standard,
        texturePolicy: TexturePolicy = TexturePolicy(),
        overwrite: Bool = true,
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        writeFile: @escaping @Sendable (String, URL) throws -> Void = { text, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.texturePolicy = texturePolicy
        self.overwrite = overwrite
        self.fileExists = fileExists
        self.writeFile = writeFile
        self.now = now
    }

    /// Runs every job in order, calling `onProgress` after each completes so
    /// a CLI or window can stream a live log.
    public func run(
        _ jobs: [BatchJob],
        onProgress: (BatchItemResult) -> Void = { _ in }
    ) async -> BatchReport {
        var results: [BatchItemResult] = []
        results.reserveCapacity(jobs.count)
        for job in jobs {
            let result = await run(job)
            onProgress(result)
            results.append(result)
        }
        return BatchReport(items: results)
    }

    private func run(_ job: BatchJob) async -> BatchItemResult {
        let start = now()
        let inputPath = job.input.path
        let outputPath = job.output.path

        if !overwrite, fileExists(job.output) {
            return BatchItemResult(
                input: inputPath, output: outputPath, status: .skipped,
                message: "output exists (overwrite off)",
                durationSeconds: now().timeIntervalSince(start))
        }

        do {
            let outcome = try await SingleFileConverter.convert(
                input: job.input, registry: registry, texturePolicy: texturePolicy)
            try writeFile(outcome.usda, job.output)
            return BatchItemResult(
                input: inputPath,
                output: outputPath,
                status: .succeeded,
                triangleCount: outcome.triangleCount,
                materialCount: outcome.materialCount,
                warningCount: outcome.diagnostics.filter { $0.severity == .warning }.count,
                errorCount: outcome.diagnostics.filter { $0.severity == .error }.count,
                durationSeconds: now().timeIntervalSince(start))
        } catch {
            let message = (error as? ConversionError).map(\.description) ?? "\(error)"
            return BatchItemResult(
                input: inputPath, output: outputPath, status: .failed,
                message: message, durationSeconds: now().timeIntervalSince(start))
        }
    }
}
