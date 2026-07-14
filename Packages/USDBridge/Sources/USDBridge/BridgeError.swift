import Foundation

/// Typed errors for the Python/usd-core boundary (specs/architecture.md:
/// typed errors per module with user-facing recovery suggestions).
public enum BridgeError: Error, Equatable, LocalizedError {
    /// No usable Python runtime with `pxr` (usd-core) was found.
    case pythonUnavailable(detail: String)
    /// The bridge process/interpreter failed; carries the Python traceback.
    case executionFailed(pythonTraceback: String)
    /// The snapshot payload could not be decoded.
    case malformedSnapshot(detail: String)
    /// The requested file does not exist or is not a USD document.
    case unreadableFile(path: String)

    public var errorDescription: String? {
        switch self {
        case .pythonUnavailable(let detail):
            return "Python runtime unavailable: \(detail)"
        case .executionFailed(let traceback):
            return "USD bridge call failed: \(traceback)"
        case .malformedSnapshot(let detail):
            return "Could not decode stage snapshot: \(detail)"
        case .unreadableFile(let path):
            return "Cannot read USD file at \(path)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pythonUnavailable:
            return "Run scripts/fetch-python-runtime.sh, or set DICYANIN_PYTHON to a Python 3 with the usd-core package installed. The viewer keeps working without it."
        case .executionFailed:
            return "See the log drawer for the full Python traceback."
        case .malformedSnapshot:
            return "The file may use USD features this build cannot snapshot yet. Please file an issue with the asset."
        case .unreadableFile:
            return "Check that the file exists and has a .usdz/.usda/.usdc/.usd extension."
        }
    }
}

/// Whether editing/conversion features are available (specs/usd-bridge.md —
/// Failure & Recovery: the app degrades to viewer-only without Python).
public enum BridgeAvailability: Equatable, Sendable {
    case available(pythonPath: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
