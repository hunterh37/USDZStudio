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
            6. If the object realistically OPENS/CLOSES/SWINGS (a case or chest lid, a door, a \
            laptop screen, a cap, a drawer), give the moving part a real hinge with `create_joint` \
            (revolute) or slider (prismatic) and verify it with `set_joint_state` — don't ship it \
            fused or fake the motion. See the `author-hinged-object` prompt.
            7. Finish with `check_compliance {}` and `save {}`.
            """))

        server.register(MCPPrompt(
            name: "sculpt-from-image",
            description: "Rebuild a reference image as a native USD object via the staged-sculpt pipeline.",
            text: """
            Reconstruct a reference image as a USD object with the staged-sculpt loop. Your \
            tokens go to visual judgment; the tools do the mechanical work.
            0. `sculpt_probe { imagePath }` — vet technical fitness first (pass the image path so \
            the tool decodes true dimensions + alpha; width/height still work if you have no file). \
            A `unusable` verdict means stop; note `recommendedMaxComponents` as your budget ceiling.
            1. `sculpt_assess { hints, imagePath }` — describe the object with a few tags and give \
            the image (path or pixel size). Read back the objectClass, complexity, and the \
            acceptance `policy`: its `minScore` is your subjective pass threshold, its \
            `similarityFloor` is the deterministic floor a render must clear, and \
            `requireCompliance` means the finished object must pass the AR gate to complete.
            2. Enumerate identity details first, then author the spec: \
            `sculpt_author_spec { spec }` with a component tree of primitives / library prefabs, \
            materials, and a detailInventory whose every item is mapped to a component or material. \
            Declare each non-root component's `attachment` (weld/socket/pin) so nothing floats; \
            add `refinements` (real inset ops) for the formRefinement pass, `lights` (real UsdLux), \
            `lodTiers` and an `optimization` weld for the optimization pass; give high-value \
            details a `minScore`. If the object realistically opens/swings (case or chest lid, \
            door, cap, drawer), declare its `joints` (revolute hinge / prismatic slider, with an \
            axis + a pivot point on the hinge line) so the interaction pass authors real \
            articulation — see the `author-hinged-object` prompt.
            3. `sculpt_validate_spec { strictQuality: true }` — if it returns an error, fix the \
            listed problems in the spec and re-author until it passes. No build happens until it does.
            4. For each locked pass, in order (blockout → structural → formRefinement → material → \
            surface → lighting → interaction → optimization):
               a. `sculpt_build_pass {}` to author that pass into the stage.
               b. `render_views {}` to capture the pass — ideally a few angles.
               c. `sculpt_comparison_sheet { referencePath, renderPath }` (or `{ views: [...] }` \
            for a multi-angle turntable) — it writes the sheet AND returns `measuredSimilarity` \
            (the worst view), the deterministic fidelity number.
               d. Judge the sheet, then `sculpt_review { decision, score, renderPath, \
            comparisonSheetPath, measuredSimilarity, featureScores? }` (forward the \
            `measuredSimilarity` from step c; pass per-detail scores as `featureScores` so the \
            final `continue` clears every feature threshold):
                  - `continue` needs render + sheet + score >= minScore AND measuredSimilarity >= \
            similarityFloor; it unlocks the next pass (the final `continue` also runs the AR gate);
                  - `refineSpec` / `refineCode` keep you on the pass to fix the spec or rebuild;
                  - `requestInput` pauses for the user; `stop` halts.
            5. Check progress any time with `sculpt_status {}` (shows the last measured similarity \
            and the floor). Finish with `check_compliance {}` and `save {}` once complete.
            """))

        server.register(MCPPrompt(
            name: "author-hinged-object",
            description: "Make a part open, close, or swing about a hinge/slider (lid, door, cap, drawer).",
            text: """
            Give a part a working hinge or slider so it opens, closes, or swings — an \
            AirPods-case lid, a chest lid, a door, a bottle cap, a drawer. This authors proper \
            Xform ops (PRD §5.3 "open the door"), RealityKit/QuickLook-clean, fully undoable.
            1. Identify the MOVING part (a prim) with `query_scene` / `get_prim`, and read its \
            world bbox — you place the hinge on one of its edges.
            2. Pick the hinge geometry, both in the part's PARENT local space:
               - `axis`: the direction the hinge line runs (a lid that flips up about its rear \
            edge hinges around the X axis → [1, 0, 0]).
               - `pivot`: a point ON that hinge line (the midpoint of the rear-top edge), NOT the \
            part's centre — this is what makes it swing about the edge instead of spinning in place.
            3. `create_joint { target, kind: "revolute", axis, pivot, openValue: 105 }` \
            (degrees). For a drawer use `kind: "prismatic"` and `openValue` in scene units along \
            the axis. It inserts a `<part>_pivot` Xform and leaves the part exactly where it was \
            when closed; it returns `pivotPath` and the state names ["closed", "open"].
            4. Preview: `set_joint_state { target: <pivotPath>, state: "open" }` then \
            `render_views {}`; check the part swings about the intended edge. Flip back with \
            `state: "closed"`, or scrub with `set_joint_state { target, value: 45 }`.
            5. `validate {}` (zero new errors) and `check_compliance { profile: "arkit" }` \
            (`isExportAllowed` must stay true — the hinge is standard Xform ops). Then `save {}`.
            The default profile ships the part in its closed pose with the hinge described on the \
            pivot for runtime tooling; switchable USD variants and baked swing animation are \
            full-USD-profile enhancements.
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

        server.register(MCPPrompt(
            name: "identify-and-animate",
            description: "Animate a rigged skeleton without guessing joint paths, self-validating each step.",
            text: """
            Author skeletal animation with verification in the loop:
            1. `list_joints { prim }` — see the real joint hierarchy (never guess paths).
            2. `identify_skeleton { prim }` — review the canonical map. If a required bone is \
            unmatched or its confidence is low, inspect further with `list_joints` or ask the user \
            BEFORE authoring. Guessing is designed out of the loop.
            3. Author: `solve_ik { chain, target }` (handle a non-converged SolveResult), \
            `set_joint_pose`, and `set_keyframe { timeCode }` / `create_clip` on the timeline.
            4. `render_pose` then `assess_motion` — the deterministic measuredMotionQuality.
            5. `rig_review { decision: "continue", subjectiveScore }` — the continue-gate requires a \
            render, a measurement ≥ the floor, AND a subjective score ≥ threshold. If rejected, \
            `refinePose`/`resolve` (re-solve or re-key) and loop.
            6. `check_compliance { profile: "arkit" }`, then `save`.
            """))

        server.register(MCPPrompt(
            name: "retarget-motion",
            description: "Retarget a clip onto a canonical-mapped humanoid, minimizing foot-slide.",
            text: """
            Retarget motion between humanoids:
            1. `identify_skeleton` on BOTH the source and target rigs; resolve low-confidence bones first.
            2. `retarget_clip { sourcePrim, targetPrim, sampleTimes }` — rest-pose reconciliation + \
            hip-height/scale normalization are applied automatically.
            3. `render_pose` → `assess_motion` with `footJoints` set, watching foot-slide and \
            seam-continuity especially.
            4. `rig_review` loop until the continue-gate passes, then `check_compliance` and `save`.
            """))

        server.register(MCPPrompt(
            name: "auto-rig-mesh",
            description: "Fit a skeleton to an unrigged mesh, bind weights, and test-pose it.",
            text: """
            Auto-rig an unrigged mesh:
            1. `auto_rig { mesh, kind: "humanoid" }` — review the proposed skeleton (`list_joints`); \
            nudge/confirm the fit.
            2. `solve_weights { mesh }` — heat/bone-glow binding, clamped to the export influence cap.
            3. A test `solve_ik` pose to sanity-check the bind, then `render_pose` → `assess_motion` \
            → `rig_review`.
            """))
    }
}
