import Foundation

/// §6 Workflow recipes as MCP Prompts — curated multi-step templates for the
/// flows agents most often fumble, each naming exact tools, parameter
/// conventions, and gate expectations (RTX Remix credits these with
/// materially reducing multi-step errors).
public enum WorkflowPrompts {

    public static func register(on server: MCPServer) {
        server.register(MCPPrompt(
            name: "import-and-normalize",
            description: "Import an external asset safely: import, verify scale, validate, fix.",
            text: """
            Import an asset into the stage the safe way:
            1. Call `import_asset { url }`. It grafts the model under a new root Xform \
            and auto-normalizes scale; read `path`, `primIds`, and `validation` from the result.
            2. Call `check_mesh { path }` on each imported Mesh prim (find them with \
            `query_scene { type: "Mesh" }`). Fix or remove non-manifold geometry.
            3. Call `score {}`. If the scaleSanity gate fails, call \
            `normalize_asset { path, targetMaxExtent }` with the object's plausible real size.
            4. Only proceed to placement (`set_transform` with `relativeTo`) once `score` passes.
            Use primIds (not paths) in later calls — they survive renames.
            """))

        server.register(MCPPrompt(
            name: "recolor-material",
            description: "Change an object's color without corrupting existing bindings.",
            text: """
            Recolor an object safely:
            1. `get_prim { path }` — check `material` in the result. If a material is bound, \
            find its shader prim via `query_scene { type: "Material" }` and set \
            `inputs:diffuseColor` on the surface shader with \
            `set_attribute { path, name: "inputs:diffuseColor", type: "vector", value: [r, g, b] }`.
            2. If nothing is bound, call `create_material { target, baseColor: [r, g, b] }`.
            3. Verify with `validate {}` — zero new errors expected. Undo with `undo` if not.
            """))

        server.register(MCPPrompt(
            name: "build-validate-score-loop",
            description: "The closed-loop build discipline: mutate → validate → score until gates pass.",
            text: """
            Build iteratively with verification in the loop (budget roughly one verify call \
            per 2-3 mutations — verification beats extra generation attempts):
            1. Sketch the scene as a prim hierarchy first: `create_prim` for groups, \
            `create_mesh` for parametric geometry, `import_asset` for real assets.
            2. Place objects declaratively: `set_transform { path, relativeTo: { anchor, rule: \
            "on_top" | "left_of" | ..., align: "center", gap } }` — never guess raw coordinates.
            3. After each 2-3 mutations call `score {}`. Read the failing gates:
               - schema → run `validate {}` and fix each diagnostic (worst first)
               - meshIntegrity → `check_mesh { path }` per failure, repair or rebuild
               - scaleSanity → `normalize_asset { path, targetMaxExtent }`
               - spatial → re-place offending pairs with `set_transform` + `relativeTo` and a gap
            4. Renders are for visual judgment only: call `render_views {}` sparingly, at \
            milestones, not after every step. Use `render_views { statsOnly: true }` or `raycast` \
            when you need confirmation rather than judgment.
            5. Every mutation returns an `undoToken` — snapshot one before risky steps and \
            roll back with `undo_to { token }` instead of hand-reversing mistakes.
            6. Finish with `check_compliance {}` and `save {}`.
            """))

        server.register(MCPPrompt(
            name: "fix-validation-errors",
            description: "Systematically clear validation diagnostics, worst first.",
            text: """
            Clear validation problems methodically:
            1. `validate {}` — list diagnostics; handle severity `error` first, then `warning`.
            2. For each diagnostic use its `rule` and `path`:
               - stage.metersPerUnit / stage.upAxis → fix stage metadata via the appropriate tool
               - mesh.* rules → `check_mesh { path }` for exact violations, then `edit_mesh` \
            or rebuild the prim with `create_mesh`
               - material/binding rules → `create_material { target }` for unbound meshes
            3. Re-run `validate {}` after each fix; confirm the count went DOWN. If a fix adds \
            new errors, `undo` immediately.
            4. Finish with `check_compliance { profile: "arkit" }` — `isExportAllowed` must be true.
            """))
    }
}
