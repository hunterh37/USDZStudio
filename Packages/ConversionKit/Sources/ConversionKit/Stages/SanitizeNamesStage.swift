import Foundation
import USDCore

/// USD-legal identifier rules, delegated to USDCore's single source of
/// truth (`PrimPath.sanitizedName` / `isValidName`).
public enum USDNameSanitizer {
    /// Makes any string a legal USD prim name.
    public static func sanitize(_ name: String) -> String {
        PrimPath.sanitizedName(from: name)
    }

    /// `true` when the name is already a legal USD identifier.
    public static func isLegal(_ name: String) -> Bool {
        PrimPath.isValidName(name)
    }
}

/// Stage 3 of the standard sequence (specs/conversion-pipeline.md):
/// USD-legal prim names, deduped among siblings, original preserved
/// in diagnostics so nothing is silently rewritten.
public struct SanitizeNamesStage: ConversionStage {
    public let id = "sanitize-names"

    public init() {}

    public func process(_ context: inout ConversionContext) async throws {
        var diagnostics: [Diagnostic] = []
        context.scene.rootNodes = sanitize(context.scene.rootNodes, diagnostics: &diagnostics)
        for i in context.scene.meshes.indices {
            let original = context.scene.meshes[i].name
            let clean = USDNameSanitizer.sanitize(original)
            if clean != original {
                context.scene.meshes[i].name = clean
                diagnostics.append(renamed(original, to: clean))
            }
        }
        for i in context.scene.materials.indices {
            let original = context.scene.materials[i].name
            let clean = USDNameSanitizer.sanitize(original)
            if clean != original {
                context.scene.materials[i].name = clean
                diagnostics.append(renamed(original, to: clean))
            }
        }
        context.diagnostics.append(contentsOf: diagnostics)
    }

    private func renamed(_ original: String, to clean: String) -> Diagnostic {
        Diagnostic(severity: .info, stage: id, message: "renamed \"\(original)\" → \"\(clean)\"")
    }

    private func sanitize(_ nodes: [SceneNode], diagnostics: inout [Diagnostic]) -> [SceneNode] {
        var seen: Set<String> = []
        return nodes.map { node in
            var node = node
            let original = node.name
            var clean = USDNameSanitizer.sanitize(original)
            if seen.contains(clean) {
                var counter = 1
                while seen.contains("\(clean)_\(counter)") { counter += 1 }
                clean = "\(clean)_\(counter)"
            }
            seen.insert(clean)
            if clean != original {
                node.name = clean
                diagnostics.append(renamed(original, to: clean))
            }
            node.children = sanitize(node.children, diagnostics: &diagnostics)
            return node
        }
    }
}
