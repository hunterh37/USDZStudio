import Foundation

/// Injectable filesystem seam so locator logic is fully unit-testable.
public protocol FileExistenceChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    /// Whether the interpreter at `path` can `import pxr` (usd-core present).
    ///
    /// The default implementation treats any executable as capable, keeping
    /// pure-logic stubs simple; `SystemFileChecker` overrides it with a real
    /// probe so the locator never hands back a usd-core-less interpreter when
    /// a working one is available.
    func canImportUSD(atPath path: String) -> Bool
}

extension FileExistenceChecking {
    public func canImportUSD(atPath path: String) -> Bool {
        isExecutableFile(atPath: path)
    }
}

public struct SystemFileChecker: FileExistenceChecking {
    public init() {}
    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Runs `<path> -c "import pxr"` and reports whether it exits cleanly.
    // coverage:disable — subprocess seam; exercised by the real-usd-core integration suite, not unit-measurable.
    public func canImportUSD(atPath path: String) -> Bool {
        guard isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import pxr"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    // coverage:enable
}

/// Finds the Python interpreter the bridge should use, in priority order:
/// 1. `DICYANIN_PYTHON` environment override
/// 2. the fetched runtime under `Resources/Python/runtime/bin/python3`
/// 3. common system interpreters
///
/// Among the existing candidates the locator prefers one that can actually
/// `import pxr`, so a system Python without usd-core is never chosen ahead of
/// a working interpreter. When none can import usd-core it falls back to the
/// first existing candidate, preserving the actionable `pythonUnavailable`
/// error (callers still smoke-test via `BridgedStage.availability`).
public struct PythonRuntimeLocator: Sendable {

    public var environment: [String: String]
    public var bundledRuntimeRoot: String
    public var checker: any FileExistenceChecking

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledRuntimeRoot: String = "Resources/Python/runtime",
        checker: any FileExistenceChecking = SystemFileChecker()
    ) {
        self.environment = environment
        self.bundledRuntimeRoot = bundledRuntimeRoot
        self.checker = checker
    }

    /// Candidate interpreter paths in priority order (before existence filtering).
    public var candidatePaths: [String] {
        var paths: [String] = []
        if let override = environment["DICYANIN_PYTHON"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(bundledRuntimeRoot + "/bin/python3")
        paths.append(contentsOf: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ])
        return paths
    }

    /// Interpreter the bridge should use: the first existing candidate that can
    /// `import pxr`, or — if none can — the first existing candidate, or `nil`.
    public func locate() -> String? {
        let existing = candidatePaths.filter { checker.isExecutableFile(atPath: $0) }
        return existing.first { checker.canImportUSD(atPath: $0) } ?? existing.first
    }
}
