import Foundation

/// Decides when a headless `openusdz mcp` session should bring up the GUI so the
/// user can WATCH the agent work (specs/agent-live-editing.md).
///
/// The relay only ever *observed* whether the editor was already running; it
/// never started it. So a session begun with the app closed ran entirely
/// in-process and invisible — the agent could build a whole model before
/// anything appeared on screen. The product contract is now **visible by
/// default**: the moment the agent issues its first stage-mutating tool call,
/// we launch USDZ Studio on the served document so that call — and every one
/// after it — lands live in the viewport. Read-only inspection at the start of a
/// session (`capabilities`, `query_scene`, `validate`, sculpt/rig probes, …)
/// does NOT pop a window; only a real edit does. `--headless` opts out entirely.
enum AutoLaunch {

    /// The GUI app's display name, as registered with LaunchServices
    /// (App/Info.plist `CFBundleDisplayName`). Passed to `/usr/bin/open -a`.
    static let appName = "USDZ Studio"

    /// Tools that inspect or render but never mutate the stage — issuing one of
    /// these must NOT launch the app, so read-only sessions stay windowless and
    /// the launch fires on the first genuine edit rather than the agent's
    /// opening `capabilities`/`query_scene` handshake. Everything NOT listed here
    /// is treated as mutating (fail toward visibility, matching the default):
    /// a newly added editing tool reveals the window without a code change here.
    ///
    /// `open_in_app` is intentionally read-only for launch purposes — it does its
    /// own revealing, so it must not also trip the auto-launch path.
    static let nonMutatingTools: Set<String> = [
        // .read
        "capabilities", "query_scene", "get_prim", "scene_stats", "list_variants", "describe_scene",
        // .verify (set_strictness tunes session config, not the stage)
        "validate", "check_compliance", "set_strictness", "check_mesh", "score",
        // .render (side-effects to disk / camera only; open_in_app reveals itself)
        "open_in_app", "render_views", "find_best_view", "sculpt_align_pose", "raycast",
        // .sculpt probes/authoring that don't mutate the stage (build_pass does)
        "sculpt_probe", "sculpt_assess", "sculpt_author_spec", "sculpt_validate_spec",
        "sculpt_review", "sculpt_status", "sculpt_comparison_sheet",
        // .rig inspection/measurement (pose/ik/keyframe/weights/auto_rig mutate)
        "list_joints", "identify_skeleton", "rig_status", "render_pose", "assess_motion", "rig_review",
        // .asset lookups that don't touch the stage (import/generate/fetch/normalize do)
        "search_assets", "asset_job_status",
    ]

    /// True when `line` is a `tools/call` for a tool that mutates the stage.
    static func isMutatingToolCall(_ line: String) -> Bool {
        guard let name = RelayCodec.toolCallName(line) else { return false }
        return !nonMutatingTools.contains(name)
    }

    /// The single launch decision, pure and testable: fire exactly once, only
    /// when auto-launch is enabled, no editor is already live, we haven't already
    /// tried, and this line is a stage mutation.
    static func shouldLaunch(
        line: String,
        autoLaunchEnabled: Bool,
        editorLive: Bool,
        alreadyAttempted: Bool
    ) -> Bool {
        guard autoLaunchEnabled, !editorLive, !alreadyAttempted else { return false }
        return isMutatingToolCall(line)
    }

    // coverage:disable — shells out to the real GUI launcher; the decision that
    // gates it (`shouldLaunch`/`isMutatingToolCall`) is unit-tested, and driving
    // an actual app launch belongs to the end-to-end recipe.
    /// Launch (or foreground) USDZ Studio on `fileURL` so the served document
    /// becomes the app's hosted, live-editing stage. Non-blocking; failures are
    /// swallowed — the caller falls back to in-process serving if the endpoint
    /// never comes up, so a missing app degrades to headless rather than hanging.
    static func launchApp(fileURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, fileURL.path]
        try? process.run()
    }
    // coverage:enable
}
