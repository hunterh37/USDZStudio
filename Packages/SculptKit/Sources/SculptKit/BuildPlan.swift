import Foundation

/// A single declarative build instruction. SculptKit never touches a USD stage
/// itself — it emits an ordered list of these, and the AgentMCP `.sculpt` tool
/// group realizes them through the `EditSession.mutate` funnel. This keeps the
/// pipeline logic pure and 100%-testable.
public enum BuildStep: Sendable, Equatable {
    /// Create a container Xform. `parentPath` nil means the stage root.
    case createGroup(name: String, parentPath: String?)
    /// Create a parametric primitive Mesh.
    case createMesh(name: String, parentPath: String?, primitive: ShapeKind.Primitive,
                    width: Double, height: Double, depth: Double,
                    radius: Double, segments: Int)
    /// Instantiate a built-in `ShapeLibrary` prefab by entry id.
    case createLibraryMesh(name: String, parentPath: String?, entryID: String)
    /// Set a prim's local transform.
    case setTransform(path: String, translation: [Double],
                      rotationEulerDegrees: [Double], scale: [Double])
    /// Create a UsdPreviewSurface material and bind it to the target prim,
    /// carrying the full channel set (scalars + optional texture maps) so the
    /// executor authors real image channels, not just a flat colour.
    case createMaterial(targetPath: String, material: MaterialSpec)
    /// Create a real `UsdLux` light of `kind` under the sculpt root. Emitted by
    /// the lighting pass; the executor authors the typed light prim + channels.
    case createLight(name: String, parentPath: String?, kind: LightSpec.Kind,
                     intensity: Double, color: [Double])
    /// Author a projected-texture / de-light descriptor (camera pose + target
    /// UV set) as a `sculptProjectedTexture` string attribute on the sculpt
    /// root. Emitted by the surface pass; the executor realizes the projection.
    case projectTexture(rootPath: String, descriptorJSON: String)
    /// Author the LOD manifest (tiers) as a `sculptLOD` string attribute on the
    /// sculpt root. Emitted by the optimization pass.
    case authorLOD(rootPath: String, manifestJSON: String)
    /// Author the action-ready runtime manifest (nodes/sockets/colliders/
    /// destruction groups) as a custom `sculptRuntime` string attribute on the
    /// sculpt root prim.
    case authorRuntime(rootPath: String, manifestJSON: String)
    /// Apply real geometry-refinement ops to an authored prim's mesh (executed
    /// by reading the prim back into a `HalfEdgeMesh`, applying the ops, and
    /// re-authoring). Emitted by the `formRefinement` pass.
    case refineMesh(path: String, ops: [MeshRefinement])
    /// Decimate an authored prim's mesh by welding vertices within
    /// `weldDistance`. Emitted by the `optimization` pass.
    case decimateMesh(path: String, weldDistance: Double)
}

/// One expanded repetition copy: its full prim name and local transform.
struct RepetitionCopy: Equatable {
    var name: String
    var translation: [Double]
    var rotationEulerDegrees: [Double]
    var scale: [Double]
}

/// Translates the unlocked slice of a spec into build steps for one pass.
/// Only three passes author into the stage (matching img2threejs's "emit only
/// the current pass"); the rest are review/annotation passes that produce no
/// mutations but still gate the pipeline.
public enum BuildPlanner {

    /// The build steps for `pass`, or an empty plan for review-only passes.
    public static func plan(for spec: ObjectSculptSpec, pass: SculptPass) -> [BuildStep] {
        switch pass {
        case .blockout:
            return geometrySteps(spec)
        case .structural:
            return placementSteps(spec)
        case .material:
            return materialSteps(spec)
        case .surface:
            return surfaceSteps(spec)
        case .lighting:
            return lightingSteps(spec)
        case .interaction:
            return runtimeSteps(spec)
        case .optimization:
            return optimizationSteps(spec)
        case .formRefinement:
            return refinementSteps(spec)
        }
    }

    // MARK: - Form refinement: real per-node geometry ops

    /// Emit a `refineMesh` step for every geometry node (base prim + repetition
    /// copies) that declares `refinements`. Group nodes carry no mesh, so they
    /// are skipped. Stays review-only (empty) when nothing declares refinements.
    static func refinementSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        var steps: [BuildStep] = []
        walk(spec.root, parent: nil) { node, parentPath in
            let selfPath = path(for: node.name, under: parentPath)
            if node.shape.authorsGeometry, !node.refinements.isEmpty {
                for name in geometryNames(for: node) {
                    steps.append(.refineMesh(path: path(for: name, under: parentPath), ops: node.refinements))
                }
            }
            return selfPath
        }
        return steps
    }

    // MARK: - Lighting: author real UsdLux lights

    static func lightingSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        // Nothing to author unless the spec declares lights — stays review-only.
        guard !spec.lights.isEmpty else { return [] }
        let parent = "/" + spec.root.name
        var steps: [BuildStep] = []
        for light in spec.lights {
            let lightPath = path(for: light.name, under: parent)
            steps.append(.createLight(
                name: light.name, parentPath: parent, kind: light.kind,
                intensity: light.intensity, color: light.color))
            // Place the light so directional kinds actually aim (structural pass
            // never sees lights, so the lighting pass positions them itself).
            steps.append(.setTransform(
                path: lightPath, translation: light.translation,
                rotationEulerDegrees: light.rotationEulerDegrees, scale: [1, 1, 1]))
        }
        return steps
    }

    // MARK: - Optimization: author the LOD manifest

    static func optimizationSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        var steps: [BuildStep] = []
        // Real decimation: weld each geometry leaf when an optimization spec
        // with a positive weld distance is declared.
        if let optimization = spec.optimization, optimization.weldDistance > 0 {
            for leaf in geometryLeafPaths(spec) {
                steps.append(.decimateMesh(path: leaf, weldDistance: optimization.weldDistance))
            }
        }
        // Author the LOD manifest when tiers are declared.
        let manifest = LODManifest(spec: spec)
        if manifest.hasTiers, let json = try? manifest.json() {
            steps.append(.authorLOD(rootPath: "/" + spec.root.name, manifestJSON: json))
        }
        return steps
    }

    /// Full prim paths of every geometry leaf (base prim only; repetition copies
    /// share the base's topology and are welded independently at export).
    static func geometryLeafPaths(_ spec: ObjectSculptSpec) -> [String] {
        var paths: [String] = []
        walk(spec.root, parent: nil) { node, parentPath in
            let selfPath = path(for: node.name, under: parentPath)
            if node.children.isEmpty, node.shape.authorsGeometry {
                paths.append(selfPath)
            }
            return selfPath
        }
        return paths
    }

    // MARK: - Surface: projected-texture / de-light descriptor

    static func surfaceSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        // Nothing to author unless the spec declares a projection targeting a
        // real component. Stays review-only otherwise.
        guard let projection = spec.surfaceProjection,
              spec.allNodes.contains(where: { $0.name == projection.targetComponent }),
              let json = try? projection.json() else { return [] }
        return [.projectTexture(rootPath: "/" + spec.root.name, descriptorJSON: json)]
    }

    // MARK: - Interaction: author the action-ready runtime manifest

    static func runtimeSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        let manifest = RuntimeManifest(spec: spec)
        // Nothing to author when there is no runtime data — stays review-only.
        guard manifest.isActionable, let json = try? manifest.json() else { return [] }
        return [.authorRuntime(rootPath: "/" + spec.root.name, manifestJSON: json)]
    }

    /// USD path for a node given its parent path (nil parent → root child).
    static func path(for name: String, under parent: String?) -> String {
        (parent ?? "") + "/" + name
    }

    // MARK: - Blockout: geometry for every node

    static func geometrySteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        var steps: [BuildStep] = []
        walk(spec.root, parent: nil) { node, parentPath in
            let selfPath = path(for: node.name, under: parentPath)
            // Emit the base component as a real prim AND immediately place it at
            // its authored transform. Without this the geometry is baked at the
            // world origin and the per-component `translation` is dropped until
            // the structural pass runs, so a blockout-only stage is a heap of
            // overlapping parts at the floor (issue #115). The structural pass
            // re-affirms the same transforms idempotently.
            steps.append(geometryStep(named: node.name, node: node, parentPath: parentPath))
            steps.append(.setTransform(
                path: selfPath, translation: node.translation,
                rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale))
            // Repetition copies: author each prim and place it at its computed
            // transform, matching what the structural pass would set.
            for copy in copies(for: node) {
                let copyPath = path(for: copy.name, under: parentPath)
                steps.append(geometryStep(named: copy.name, node: node, parentPath: parentPath))
                steps.append(.setTransform(
                    path: copyPath, translation: copy.translation,
                    rotationEulerDegrees: copy.rotationEulerDegrees, scale: copy.scale))
            }
            return selfPath
        }
        return steps
    }

    /// The base name plus repetition-copy names for a node.
    static func geometryNames(for node: ComponentNode) -> [String] {
        [node.name] + copies(for: node).map(\.name)
    }

    /// Expanded repetition copies for a node (excluding the base), honoring the
    /// repetition `kind`. Empty when the node has no (valid) repetition.
    static func copies(for node: ComponentNode) -> [RepetitionCopy] {
        guard let rep = node.repetition, rep.count > 1, rep.step.count == 3 else { return [] }
        switch rep.kind {
        case .linear: return linearCopies(node, rep)
        case .radial: return radialCopies(node, rep)
        case .grid: return gridCopies(node, rep)
        }
    }

    static func linearCopies(_ node: ComponentNode, _ rep: RepetitionSystem) -> [RepetitionCopy] {
        (1..<rep.count).map { i in
            let offset = rep.step.map { $0 * Double(i) }
            return RepetitionCopy(
                name: "\(node.name)_\(rep.name)\(i)",
                translation: zip(node.translation, offset).map(+),
                rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale)
        }
    }

    static func radialCopies(_ node: ComponentNode, _ rep: RepetitionSystem) -> [RepetitionCopy] {
        let axis = normalized(rep.axis ?? [0, 1, 0])
        let anglePer = 360.0 / Double(rep.count)
        return (1..<rep.count).map { i in
            let angle = anglePer * Double(i) * .pi / 180
            let rotated = rotate(rep.step, around: axis, radians: angle)
            return RepetitionCopy(
                name: "\(node.name)_\(rep.name)\(i)",
                translation: zip(node.translation, rotated).map(+),
                rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale)
        }
    }

    static func gridCopies(_ node: ComponentNode, _ rep: RepetitionSystem) -> [RepetitionCopy] {
        let counts = gridDimensions(rep)
        var out: [RepetitionCopy] = []
        var index = 1
        for z in 0..<counts[2] {
            for y in 0..<counts[1] {
                for x in 0..<counts[0] {
                    if x == 0, y == 0, z == 0 { continue } // base cell
                    let offset = [Double(x) * rep.step[0], Double(y) * rep.step[1], Double(z) * rep.step[2]]
                    out.append(RepetitionCopy(
                        name: "\(node.name)_\(rep.name)\(index)",
                        translation: zip(node.translation, offset).map(+),
                        rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale))
                    index += 1
                }
            }
        }
        return out
    }

    /// Grid cell counts [nx, ny, nz]; defaults to a single row of `count` when
    /// `gridCounts` is absent or malformed.
    static func gridDimensions(_ rep: RepetitionSystem) -> [Int] {
        if let g = rep.gridCounts, g.count == 3, g.allSatisfy({ $0 >= 1 }) { return g }
        return [rep.count, 1, 1]
    }

    // MARK: - Vector helpers (Rodrigues rotation for radial repetition)

    static func normalized(_ v: [Double]) -> [Double] {
        guard v.count == 3 else { return [0, 1, 0] }
        let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        guard len > 1e-9 else { return [0, 1, 0] }
        return v.map { $0 / len }
    }

    /// Rotate vector `v` around unit axis `k` by `radians` (Rodrigues formula).
    static func rotate(_ v: [Double], around k: [Double], radians: Double) -> [Double] {
        let c = cos(radians), s = sin(radians)
        let dot = v[0] * k[0] + v[1] * k[1] + v[2] * k[2]
        let cross = [k[1] * v[2] - k[2] * v[1],
                     k[2] * v[0] - k[0] * v[2],
                     k[0] * v[1] - k[1] * v[0]]
        return (0..<3).map { i in
            v[i] * c + cross[i] * s + k[i] * dot * (1 - c)
        }
    }

    static func geometryStep(named name: String, node: ComponentNode, parentPath: String?) -> BuildStep {
        switch node.shape {
        case .group:
            return .createGroup(name: name, parentPath: parentPath)
        case .primitive(let primitive):
            return .createMesh(
                name: name, parentPath: parentPath, primitive: primitive,
                width: node.width, height: node.height, depth: node.depth,
                radius: node.radius, segments: node.segments)
        case .library(let entryID):
            return .createLibraryMesh(name: name, parentPath: parentPath, entryID: entryID)
        }
    }

    // MARK: - Structural: placement + repetition expansion

    static func placementSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        var steps: [BuildStep] = []
        walk(spec.root, parent: nil) { node, parentPath in
            let selfPath = path(for: node.name, under: parentPath)
            steps.append(.setTransform(
                path: selfPath, translation: node.translation,
                rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale))
            // Place each expanded copy at its computed transform.
            for copy in copies(for: node) {
                steps.append(.setTransform(
                    path: path(for: copy.name, under: parentPath),
                    translation: copy.translation,
                    rotationEulerDegrees: copy.rotationEulerDegrees, scale: copy.scale))
            }
            return selfPath
        }
        return steps
    }

    // MARK: - Material: author + bind

    static func materialSteps(_ spec: ObjectSculptSpec) -> [BuildStep] {
        var steps: [BuildStep] = []
        let byID = Dictionary(uniqueKeysWithValues: spec.materials.map { ($0.id, $0) })
        walk(spec.root, parent: nil) { node, parentPath in
            let selfPath = path(for: node.name, under: parentPath)
            if let materialID = node.materialID, let material = byID[materialID] {
                steps.append(.createMaterial(targetPath: selfPath, material: material))
            }
            return selfPath
        }
        return steps
    }

    // MARK: - Tree walk

    /// Depth-first walk that threads each node's resolved USD path down to its
    /// children. `visit` returns the node's own path.
    static func walk(_ node: ComponentNode, parent: String?, _ visit: (ComponentNode, String?) -> String) {
        let selfPath = visit(node, parent)
        for child in node.children {
            walk(child, parent: selfPath, visit)
        }
    }
}
