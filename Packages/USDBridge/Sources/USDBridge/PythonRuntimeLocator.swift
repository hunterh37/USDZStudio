import Foundation

/// Injectable filesystem seam so locator logic is fully unit-testable.
public protocol FileExistenceChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

public struct SystemFileChecker: FileExistenceChecking {
    public init() {}
    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Finds the Python interpreter the bridge should use, in priority order:
/// 1. `DICYANIN_PYTHON` environment override
/// 2. the fetched runtime under `Resources/Python/runtime/bin/python3`
/// 3. common system interpreters
///
/// Location alone doesn't guarantee usd-core is importable — callers must
/// still smoke-test `import pxr` (see `BridgedStage.availability`).
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

    /// First candidate that exists and is executable, or `nil`.
    public func locate() -> String? {
        candidatePaths.first { checker.isExecutableFile(atPath: $0) }
    }
}
