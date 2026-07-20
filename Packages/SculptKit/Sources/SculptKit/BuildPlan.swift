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
    /// Create a UsdPreviewSurface material and bind it to the target prim.
    case createMaterial(targetPath: String, baseColor: [Double])
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
        case .formRefinement, .surface, .lighting, .interaction, .optimization:
            return []
        }
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
            // Emit the base component plus any repetition copies as real prims,
            // so the structural pass has concrete paths to place.
            for name in geometryNames(for: node) {
                steps.append(geometryStep(named: name, node: node, parentPath: parentPath))
            }
            return selfPath
        }
        return steps
    }

    /// The base name plus repetition-copy names for a node.
    static func geometryNames(for node: ComponentNode) -> [String] {
        var names = [node.name]
        if let repetition = node.repetition, repetition.count > 1, repetition.step.count == 3 {
            for i in 1..<repetition.count {
                names.append("\(node.name)_\(repetition.name)\(i)")
            }
        }
        return names
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
            if let repetition = node.repetition, repetition.count > 1, repetition.step.count == 3 {
                // Copies 1..<count are offset multiples of `step` from the base.
                for i in 1..<repetition.count {
                    let offset = repetition.step.map { $0 * Double(i) }
                    let translated = zip(node.translation, offset).map(+)
                    steps.append(.setTransform(
                        path: "\(selfPath)_\(repetition.name)\(i)",
                        translation: translated,
                        rotationEulerDegrees: node.rotationEulerDegrees, scale: node.scale))
                }
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
                steps.append(.createMaterial(targetPath: selfPath, baseColor: material.baseColor))
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
