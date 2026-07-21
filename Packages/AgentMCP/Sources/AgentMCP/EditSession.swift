import Foundation
import EditingKit
import USDCore
import USDBridge
import ValidationKit

/// Structured, correctable tool failure (docs/AGENT_MCP_PLAN.md §3 —
/// "Parameter pre-validation": invalid names and out-of-range params are the
/// top observed agent failure mode; catch them before touching the stage).
public enum ToolError: Error, CustomStringConvertible, Sendable {
    case invalidParams(String)
    case primNotFound(String)
    case rejectedByValidation([String])
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .invalidParams(let m): return "invalid params: \(m)"
        case .primNotFound(let m): return "prim not found: \(m)"
        case .rejectedByValidation(let diags):
            return "rejected by strict validation: \(diags.joined(separator: "; "))"
        case .unsupported(let m): return "unsupported: \(m)"
        case .failed(let m): return m
        }
    }
}

/// Post-mutation strictness (docs/AGENT_MCP_PLAN.md §3.3, rhinomcp's modes):
/// `warn` returns diagnostics inline but commits; `strict` rolls back a
/// mutation that introduces new `.error` diagnostics; `off` skips inline
/// validation for bulk phases the agent will validate at the end.
public enum ValidationStrictness: String, Sendable, CaseIterable {
    case off, warn, strict
}

/// One mutating tool call's structured return
/// (`{ verb, diff, validation, undoToken, primIds }`, plan §3).
public struct MutationOutcome: Sendable {
    public var verb: String
    public var diff: StageDiff
    public var validation: ValidationReport?
    public var undoToken: Int
    /// Affected path → session-stable prim id.
    public var primIds: [PrimPath: String]

    public func asJSON(extra: [String: JSONValue] = [:]) -> JSONValue {
        var ids: [String: JSONValue] = [:]
        for (path, id) in primIds { ids[path.description] = .string(id) }
        var payload: [String: JSONValue] = [
            "verb": .string(verb),
            "diff": diff.asJSON,
            "undoToken": .number(Double(undoToken)),
            "primIds": .object(ids),
        ]
        if let validation { payload["validation"] = validation.asJSON }
        for (k, v) in extra { payload[k] = v }
        return .object(payload)
    }
}

/// The MCP server's authoritative per-document state: mutable stage +
/// `CommandStack` + prim-id registry + strictness (plan §2 — "MCP Server ──►
/// EditSession (owns CommandStack + BridgedStage)").
///
/// Requests are processed serially by the transport loop, so plain class
/// state is safe; nothing here touches AppKit or a live document
/// (headless composition: BridgedStage.open → InMemoryStage → CommandStack).
public final class EditSession: @unchecked Sendable {
    public let stage: InMemoryStage
    public let stack: CommandStack
    public private(set) var registry = PrimIDRegistry()
    public var strictness: ValidationStrictness
    public var profile: ValidationProfile
    public let sourceURL: URL?
    /// Save executor for usdc/usdz targets; `nil` limits saves to usda.
    public var saveExecutor: ProcessBridgeExecutor?
    /// Bridge for re-importing USD-family files (script outputs, downloads);
    /// separate from `saveExecutor` so tests can stub it.
    public var bridgeExecutor: (any BridgeExecutor)?

    /// The reference image the agent is working from (nil when none). Set via
    /// the `set_reference_image` tool and surfaced in the editor's reference
    /// panel; not part of the USD scene, so it never touches the stage or the
    /// undo stack (specs/agent-live-editing.md — "Reference panel").
    public private(set) var referenceImage: ReferenceImage?

    /// Fired whenever `referenceImage` changes so the host (app/CLI) can mirror
    /// it to the UI and/or persist the hand-off record. AgentMCP owns no
    /// transport — like `MCPEventSink`, this is a fire-and-forget notification.
    public var onReferenceImageChange: (@Sendable (ReferenceImage?) -> Void)?

    /// Set (or clear, with nil) the working reference image and notify the host.
    public func setReferenceImage(_ image: ReferenceImage?) {
        referenceImage = image
        onReferenceImageChange?(image)
    }

    public init(
        snapshot: StageSnapshot,
        sourceURL: URL? = nil,
        strictness: ValidationStrictness = .warn,
        profile: ValidationProfile = .arkit
    ) {
        self.stage = InMemoryStage(snapshot)
        self.stack = CommandStack(stage: stage)
        self.strictness = strictness
        self.profile = profile
        self.sourceURL = sourceURL
    }

    /// Bind a session to an **existing** stage + command stack rather than a
    /// fresh copy — the seam that lets the app host this session directly on
    /// its open `EditorDocument`'s stage/stack, so agent mutations run through
    /// the same `CommandStack.onChange` that refreshes the viewport
    /// (specs/agent-live-editing.md). Every tool then edits the live document.
    public init(
        sharing stage: InMemoryStage,
        stack: CommandStack,
        sourceURL: URL? = nil,
        strictness: ValidationStrictness = .warn,
        profile: ValidationProfile = .arkit
    ) {
        self.stage = stage
        self.stack = stack
        self.strictness = strictness
        self.profile = profile
        self.sourceURL = sourceURL
    }

    // MARK: - Prim resolution

    /// Resolve a tool argument that may be a `path` ("/A/B") or a `primId`
    /// ("prim-3") into a live prim path, pre-validating existence.
    public func resolve(_ args: JSONValue, key: String = "path") throws -> PrimPath {
        if let raw = args[key].stringValue {
            if raw.hasPrefix("/") {
                guard let path = PrimPath(raw) else {
                    throw ToolError.invalidParams("malformed prim path '\(raw)'")
                }
                guard stage.prim(at: path) != nil else {
                    throw ToolError.primNotFound(raw)
                }
                return path
            }
            guard let path = registry.path(for: raw) else {
                throw ToolError.primNotFound("unknown primId '\(raw)'")
            }
            guard stage.prim(at: path) != nil else {
                throw ToolError.primNotFound("primId '\(raw)' points at removed prim \(path)")
            }
            return path
        }
        throw ToolError.invalidParams("missing '\(key)' (prim path or primId)")
    }

    /// Resolve and fetch in one step (resolve pre-validates existence, so
    /// the fetch cannot fail afterwards).
    public func requirePrim(_ args: JSONValue, key: String = "path") throws -> Prim {
        let path = try resolve(args, key: key)
        // coverage:disable — resolve() already guarantees the prim exists; the fallback exists only to satisfy the optional API.
        guard let prim = stage.prim(at: path) else {
            throw ToolError.primNotFound(path.description)
        }
        // coverage:enable
        return prim
    }

    /// Mint (or fetch) the stable handle for one path.
    public func id(for path: PrimPath) -> String {
        registry.id(for: path)
    }

    /// Mint/refresh handles for a set of paths (post-mutation bookkeeping).
    public func handles(for paths: [PrimPath]) -> [PrimPath: String] {
        var out: [PrimPath: String] = [:]
        for path in paths where stage.prim(at: path) != nil {
            out[path] = registry.id(for: path)
        }
        return out
    }

    // MARK: - Transactional mutation

    /// Run one `EditCommand` through the stack with diff synthesis, inline
    /// validation, and strict-mode rollback. Every mutating tool funnels here.
    public func mutate(
        _ command: any EditCommand,
        moved: [(from: PrimPath, to: PrimPath)] = [],
        removed: [PrimPath] = []
    ) throws -> MutationOutcome {
        let before = stage.currentSnapshot
        let beforeErrors = strictness == .strict
            ? profile.engine.validate(stage).errorCount : 0

        let verb: String
        do {
            verb = try stack.run(command)
        } catch let error as StageMutationError {
            throw ToolError.failed("\(error)")
        }

        let after = stage.currentSnapshot
        let diff = StageDiff.compute(before: before, after: after)

        var report: ValidationReport?
        if strictness != .off {
            let r = profile.engine.validate(stage)
            report = r
            if strictness == .strict, r.errorCount > beforeErrors {
                let messages = r.diagnostics
                    .filter { $0.severity == .error }
                    .map { "\($0.ruleID): \($0.message)" }
                _ = try? stack.undo()
                throw ToolError.rejectedByValidation(messages)
            }
        }

        // Handle bookkeeping: moves first (rename/reparent), then removals.
        for move in moved { registry.move(from: move.from, to: move.to) }
        for path in removed { registry.invalidate(subtree: path) }

        let affected = diff.addedPrims + diff.modifiedPrims + moved.map(\.to)
        return MutationOutcome(
            verb: verb,
            diff: diff,
            validation: report,
            undoToken: stack.undoCount,
            primIds: handles(for: affected))
    }

    // MARK: - Transaction control (§3.6)

    public func undo() throws -> String? {
        do { return try stack.undo() } catch { throw ToolError.failed("undo failed: \(error)") }
    }

    public func redo() throws -> String? {
        do { return try stack.redo() } catch { throw ToolError.failed("redo failed: \(error)") }
    }

    /// Roll back until `undoCount == token` (the state right after the step
    /// that returned this token committed).
    public func undo(to token: Int) throws -> [String] {
        guard token >= 0, token <= stack.undoCount else {
            throw ToolError.invalidParams(
                "undoToken \(token) out of range (0...\(stack.undoCount))")
        }
        var undone: [String] = []
        while stack.undoCount > token {
            guard let label = try? stack.undo() else { break }
            undone.append(label)
        }
        return undone
    }

    public func save(to url: URL? = nil) async throws -> URL {
        guard let target = url ?? sourceURL else {
            throw ToolError.invalidParams("no destination: session has no sourceURL; pass 'url'")
        }
        do {
            try await StageSaver.save(stage, to: target, executor: saveExecutor)
        } catch {
            throw ToolError.failed("save failed: \(error)")
        }
        return target
    }
}

// MARK: - ValidationKit JSON bridges

public extension ValidationReport {
    var asJSON: JSONValue {
        .object([
            "errors": .number(Double(errorCount)),
            "warnings": .number(Double(warningCount)),
            "info": .number(Double(infoCount)),
            "isCompliant": .bool(isCompliant),
            "diagnostics": .array(diagnostics.map(\.asJSON)),
        ])
    }
}

public extension ValidationKit.Diagnostic {
    var asJSON: JSONValue {
        var payload: [String: JSONValue] = [
            "rule": .string(ruleID),
            "severity": .string(severity.rawValue),
            "message": .string(message),
        ]
        if let primPath { payload["path"] = .string(primPath.description) }
        return .object(payload)
    }
}
