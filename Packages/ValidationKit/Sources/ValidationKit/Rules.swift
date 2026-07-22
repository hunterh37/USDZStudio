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

/// Two sibling prims sharing a name compose to the same path, so one silently
/// shadows the other — AR QuickLook loads whichever wins and the rest vanish.
/// A hard error; the fix is to rename (sanitize) the duplicates.
public struct DuplicatePrimNameRule: ValidationRule {
    public let id = "prim.duplicateName"
    public let severity = DiagnosticSeverity.error

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        var diagnostics = check(siblings: stage.rootPrims, parentLabel: "the stage root")
        for prim in stage.allPrims() where !prim.children.isEmpty {
            diagnostics += check(siblings: prim.children, parentLabel: "'\(prim.name)'")
        }
        return diagnostics
    }

    /// Emits one diagnostic per name that appears more than once among a set of
    /// siblings, anchored to the first offending prim so the row can select it.
    private func check(siblings: [Prim], parentLabel: String) -> [Diagnostic] {
        var seen: [String: Prim] = [:]
        var flagged: Set<String> = []
        var diagnostics: [Diagnostic] = []
        for prim in siblings {
            if let first = seen[prim.name] {
                if flagged.insert(prim.name).inserted {
                    diagnostics.append(Diagnostic(
                        ruleID: id, severity: severity,
                        message: "Duplicate prim name '\(prim.name)' under \(parentLabel); names must be unique among siblings.",
                        primPath: first.path))
                }
            } else {
                seen[prim.name] = prim
            }
        }
        return diagnostics
    }
}

/// A mesh with no bound material renders with RealityKit's default gray, which
/// is rarely intended. Informational — the geometry still shows.
public struct UnboundMeshRule: ValidationRule {
    public let id = "mesh.unbound"
    public let severity = DiagnosticSeverity.info

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims()
            .filter { $0.typeName == "Mesh" && MeshTopologyRule.pointCount($0) > 0 && !Self.hasMaterialBinding($0) }
            .map { Diagnostic(ruleID: id, severity: severity, message: "\($0.name): no material bound; renders with the default material.", primPath: $0.path) }
    }

    /// True when the prim authors a non-empty `material:binding` relationship
    /// (the `material:binding:*` purpose-specific variants count too).
    static func hasMaterialBinding(_ prim: Prim) -> Bool {
        prim.relationships.contains {
            ($0.name == "material:binding" || $0.name.hasPrefix("material:binding:")) && !$0.targets.isEmpty
        }
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

/// Meshes without an authored `subdivisionScheme` inherit USD's default of
/// `catmullClark`, so a polygonal cage meant to display as-authored is instead
/// subdivided into a rounded blob (boxes → pills) by conformant renderers
/// (Hydra/Storm, QuickLook). Authoring `subdivisionScheme = "none"` keeps crisp
/// low-poly geometry. Informational — the geometry is valid either way. See #97.
public struct MissingSubdivisionSchemeRule: ValidationRule {
    public let id = "mesh.subdivision"
    public let severity = DiagnosticSeverity.info

    public init() {}

    public func evaluate(stage: any USDStageProtocol) -> [Diagnostic] {
        stage.allPrims()
            .filter { $0.typeName == "Mesh" && MeshTopologyRule.pointCount($0) > 0 && $0.attribute(named: "subdivisionScheme") == nil }
            .map { Diagnostic(ruleID: id, severity: severity, message: "\($0.name): no subdivisionScheme authored; defaults to catmullClark and will render rounded. Author \"none\" for crisp polygons.", primPath: $0.path) }
    }
}
