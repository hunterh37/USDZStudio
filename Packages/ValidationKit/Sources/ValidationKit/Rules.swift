import USDCore

// The v1 rule catalog (specs/validation.md). Each rule is a pure function of a
// stage snapshot, so it is trivially unit-testable and order-independent. Rules
// never mutate; the engine aggregates their diagnostics.

/// AR QuickLook renders geometry Y-up; a Z-up stage imports on its side unless
/// re-oriented at export. Warning, since the exporter can still fix it.
public struct UpAxisRule: ValidationRule {
    public let id = "stage.upAxis"
    public let severity = DiagnosticSeverity.warning

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        guard stage.metadata.upAxis == .z else { return [] }
        return [Diagnostic(
            ruleID: id, severity: severity,
            message: "upAxis is Z; AR QuickLook expects Y-up. Re-orient on export.")]
    }
}

/// A single-asset usdz needs a `defaultPrim` so AR QuickLook knows which root to
/// instantiate. Missing → warning; naming a prim that does not exist → error.
public struct DefaultPrimRule: ValidationRule {
    public let id = "stage.defaultPrim"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        guard let name = stage.metadata.defaultPrim else {
            return [Diagnostic(
                ruleID: id, severity: .warning,
                message: "No defaultPrim declared; AR QuickLook may fail to pick a root prim.")]
        }
        guard !stage.rootPrims.contains(where: { $0.name == name }) else { return [] }
        return [Diagnostic(
            ruleID: id, severity: .error,
            message: "defaultPrim '\(name)' does not match any root prim.")]
    }
}

/// Structural mesh checks: `faceVertexCounts` must sum to the index count, every
/// face must have ≥3 corners, and every index must reference an existing point.
/// These are hard errors — such a mesh fails to load or renders as garbage.
public struct MeshTopologyRule: ValidationRule {
    public let id = "mesh.topology"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims().filter { $0.typeName == "Mesh" }.flatMap(evaluate(mesh:))
    }

    private func evaluate(mesh: Prim) -> [Diagnostic] {
        let pointCount = Self.pointCount(mesh)
        guard let counts = Self.intArray(mesh, "faceVertexCounts"),
              let indices = Self.intArray(mesh, "faceVertexIndices") else {
            // A mesh with no topology arrays is caught by EmptyMeshRule.
            return []
        }
        var diagnostics: [Diagnostic] = []
        func flag(_ message: String) {
            diagnostics.append(Diagnostic(ruleID: id, severity: severity, message: message, primPath: mesh.path))
        }

        let expected = counts.reduce(0, +)
        if expected != indices.count {
            flag("\(mesh.name): faceVertexCounts sum (\(expected)) ≠ faceVertexIndices count (\(indices.count)).")
        }
        if counts.contains(where: { $0 < 3 }) {
            flag("\(mesh.name): a face has fewer than 3 vertices.")
        }
        if let bad = indices.first(where: { $0 < 0 || $0 >= pointCount }) {
            flag("\(mesh.name): faceVertexIndices references vertex \(bad) but the mesh has \(pointCount) points.")
        }
        return diagnostics
    }

    static func pointCount(_ mesh: Prim) -> Int {
        switch mesh.attribute(named: "points")?.value {
        case .doubleArray(let v): return v.count / 3
        case .float3Array(let v): return v.count / 3
        default: return 0
        }
    }

    static func intArray(_ mesh: Prim, _ name: String) -> [Int]? {
        if case .intArray(let v)? = mesh.attribute(named: name)?.value { return v }
        return nil
    }
}

/// A mesh prim carrying no points contributes nothing and usually signals a
/// dropped or failed import. Warning.
public struct EmptyMeshRule: ValidationRule {
    public let id = "mesh.empty"
    public let severity = DiagnosticSeverity.warning

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims()
            .filter { $0.typeName == "Mesh" && MeshTopologyRule.pointCount($0) == 0 }
            .map { Diagnostic(ruleID: id, severity: severity, message: "\($0.name): mesh has no points.", primPath: $0.path) }
    }
}

/// Meshes without authored normals fall back to faceted shading in RealityKit,
/// which looks wrong on smooth surfaces. Informational — still renders.
public struct MissingNormalsRule: ValidationRule {
    public let id = "mesh.normals"
    public let severity = DiagnosticSeverity.info

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims()
            .filter { $0.typeName == "Mesh" && MeshTopologyRule.pointCount($0) > 0 && $0.attribute(named: "normals") == nil }
            .map { Diagnostic(ruleID: id, severity: severity, message: "\($0.name): no normals authored; shading will be faceted.", primPath: $0.path) }
    }
}
