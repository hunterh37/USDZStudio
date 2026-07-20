import Foundation

/// Subprocess seam for FBX2glTF (specs/conversion-pipeline.md — Supported
/// Inputs). ConversionKit only depends on USDCore, so the runner abstraction
/// lives locally here rather than reusing USDBridge's executor. A conformer
/// converts an `.fbx` into a `.glb`/`.gltf` and returns the produced file URL.
public protocol FBX2glTFRunning: Sendable {
    /// Converts `input` into a glTF/GLB written under `outputDir`, returning
    /// the produced file URL. The runner keeps any emitted `.bin`/textures in
    /// `outputDir` so the downstream GLTF importer resolves them relative to it.
    func convert(input: URL, outputDir: URL) async throws -> URL
}

/// FBX import: shell out to FBX2glTF to produce glTF/GLB, then hand the result
/// to the native `GLTFImporter`. FBX2glTF's output (`.bin`, textures) lands in
/// the same temp dir as the produced glTF so relative references resolve.
public struct FBXImporter: AssetImporter {
    public static let supportedExtensions = ["fbx"]

    private let runner: any FBX2glTFRunning

    /// Injects a runner (tests supply a fake); defaults to the production
    /// process-spawning runner that locates the fetched FBX2glTF binary.
    public init(runner: any FBX2glTFRunning = FBX2glTFRunner()) {
        self.runner = runner
    }

    public enum FBXImportError: Error, Equatable {
        case binaryNotFound(String)
        case conversionFailed(stderr: String)
        case noOutputProduced

        public var message: String {
            switch self {
            case .binaryNotFound(let path):
                return "FBX2glTF binary not found at \(path); run scripts/fetch-fbx2gltf.sh or set FBX2GLTF_PATH"
            case .conversionFailed(let stderr):
                return "FBX2glTF conversion failed: \(stderr)"
            case .noOutputProduced:
                return "FBX2glTF produced no glTF/GLB output"
            }
        }
    }

    public func importAsset(at url: URL, options: ImportOptions) async throws -> ImportResult {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbx-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let producedURL = try await runner.convert(input: url, outputDir: outputDir)

        var result = try await GLTFImporter().importAsset(at: producedURL, options: options)
        result.diagnostics.insert(
            Diagnostic(
                severity: .info, stage: "fbx-convert",
                message: "converted \(url.lastPathComponent) via FBX2glTF → \(producedURL.lastPathComponent)"),
            at: 0)
        return result
    }
}

/// Production runner: locates the fetched FBX2glTF binary and spawns it.
public struct FBX2glTFRunner: FBX2glTFRunning {
    /// Absolute path to the FBX2glTF binary. Defaults to the location
    /// `scripts/fetch-fbx2gltf.sh` installs to, overridable via `FBX2GLTF_PATH`.
    public var binaryPath: String

    /// The install path used by `scripts/fetch-fbx2gltf.sh`, relative to a
    /// repo/bundle root. Resolved against the current working directory here;
    /// the app supplies an absolute override in production.
    public static let defaultRelativePath = "Resources/Tools/FBX2glTF"

    public init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
            ?? ProcessInfo.processInfo.environment["FBX2GLTF_PATH"]
            ?? FileManager.default.currentDirectoryPath + "/" + Self.defaultRelativePath
    }

    public func convert(input: URL, outputDir: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw FBXImporter.FBXImportError.binaryNotFound(binaryPath)
        }
        // FBX2glTF's `--output <prefix> --binary` writes `<prefix>.glb`.
        let prefix = outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
        let producedURL = prefix.appendingPathExtension("glb")

        let stderr = try Self.spawn(
            binary: binaryPath,
            arguments: ["--binary", "--input", input.path, "--output", prefix.path])

        guard FileManager.default.fileExists(atPath: producedURL.path) else {
            if !stderr.isEmpty {
                throw FBXImporter.FBXImportError.conversionFailed(stderr: stderr)
            }
            throw FBXImporter.FBXImportError.noOutputProduced
        }
        return producedURL
    }

    /// Spawns the binary and returns its stderr; throws on non-zero exit.
    /// Mirrors `ProcessBridgeExecutor.run` in USDBridge.
    static func spawn(binary: String, arguments: [String]) throws -> String {
        // coverage:disable — real subprocess spawn is unavailable in headless
        // CI (no FBX2glTF binary); every caller branch is covered via an
        // injected fake FBX2glTFRunning. This is the only excluded body.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw FBXImporter.FBXImportError.conversionFailed(
                stderr: "failed to launch \(binary): \(error.localizedDescription)")
        }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errString = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw FBXImporter.FBXImportError.conversionFailed(
                stderr: errString.isEmpty ? "exit status \(process.terminationStatus)" : errString)
        }
        return errString
        // coverage:enable
    }
}
