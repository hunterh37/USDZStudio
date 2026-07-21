import Foundation

/// Server-level guidance surfaced to the model through the `initialize`
/// response's `instructions` field. Clients fold this into the agent's system
/// prompt, so this is where cross-cutting "you can do this — reach for it when
/// it fits" advice lives (as opposed to per-tool `description` strings, which
/// the model only sees once it inspects a specific tool).
///
/// Kept deliberately short and high-signal: what the server is, the build
/// discipline, and the capabilities an agent most often *forgets it has* —
/// chief among them rigid articulation (hinges), which should be applied to any
/// object that realistically opens or swings, not only when the user says so.
public enum AgentInstructions {
    public static let text = """
    You are editing a live USD stage through the OpenUSDZEditor agent API. The USD stage is the \
    single source of truth; every mutation is an undoable command that is validated inline. Build \
    with verification in the loop — mutate, then `validate` / `score` / `check_compliance` — rather \
    than generating blindly. Prefer primIds over paths (they survive renames), place parts \
    declaratively with `set_transform { relativeTo }`, and consult the workflow prompts \
    (`prompts/list`) for the multi-step flows: import-and-normalize, build-validate-score-loop, \
    sculpt-from-image, recolor-material, fix-validation-errors, and author-hinged-object.

    Make objects behave like the real thing. Many real objects have a part that OPENS, CLOSES, or \
    SWINGS about a hinge or slides in a track — an AirPods/earbuds case lid, a laptop screen, a \
    chest or box lid, a door or cabinet, a mailbox flap, a bottle/flip cap, a drawer, a car door \
    or hood, a book cover, a clamshell phone. Whenever you build or import an object that \
    realistically articulates, give the moving part a real joint with `create_joint` (revolute for \
    a hinge, prismatic for a drawer) and drive it with `set_joint_state` — do NOT leave it as a \
    fused, static lump, and do NOT fake the motion by eyeballing a rotated transform about the \
    wrong point. The joint hinges about the correct edge, keeps the closed pose exactly in place, \
    is fully undoable, and stays RealityKit/QuickLook-clean. Follow the `author-hinged-object` \
    prompt for the exact steps. When reconstructing from a reference image via the sculpt \
    pipeline, declare such articulations up front in the spec's `joints` (see `sculpt_author_spec`) \
    so the interaction pass authors them. Use judgment: add joints where they are physically real, \
    not to objects that are genuinely one rigid piece (a mug, a rock, a solid figurine).
    """
}
