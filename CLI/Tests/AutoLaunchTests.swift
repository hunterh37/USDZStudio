import Testing
@testable import openusdz

/// The pure "should the GUI come up now?" decision (the actual `/usr/bin/open`
/// launch is a coverage-disabled IO shell, exercised end-to-end).
@Suite struct AutoLaunchTests {

    private func call(_ tool: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":{}}}"
    }

    @Test func mutatingToolsClassifiedByAllowlist() {
        // Real edits mutate → launch-worthy.
        #expect(AutoLaunch.isMutatingToolCall(call("create_mesh")))
        #expect(AutoLaunch.isMutatingToolCall(call("create_prim")))
        #expect(AutoLaunch.isMutatingToolCall(call("generate_asset")))
        #expect(AutoLaunch.isMutatingToolCall(call("import_asset")))
        #expect(AutoLaunch.isMutatingToolCall(call("set_transform")))
        #expect(AutoLaunch.isMutatingToolCall(call("sculpt_build_pass")))
        #expect(AutoLaunch.isMutatingToolCall(call("set_joint_pose")))
        #expect(AutoLaunch.isMutatingToolCall(call("undo")))
        // An unknown/newly-added tool fails toward visibility.
        #expect(AutoLaunch.isMutatingToolCall(call("some_future_edit_tool")))
    }

    @Test func readOnlyToolsDoNotLaunch() {
        // The opening inspection handshake must not pop a window.
        #expect(!AutoLaunch.isMutatingToolCall(call("capabilities")))
        #expect(!AutoLaunch.isMutatingToolCall(call("query_scene")))
        #expect(!AutoLaunch.isMutatingToolCall(call("validate")))
        #expect(!AutoLaunch.isMutatingToolCall(call("score")))
        #expect(!AutoLaunch.isMutatingToolCall(call("sculpt_probe")))
        #expect(!AutoLaunch.isMutatingToolCall(call("list_joints")))
        #expect(!AutoLaunch.isMutatingToolCall(call("search_assets")))
        // open_in_app reveals itself — must not also trip auto-launch.
        #expect(!AutoLaunch.isMutatingToolCall(call("open_in_app")))
        // Non-tools/call frames are never mutating.
        #expect(!AutoLaunch.isMutatingToolCall(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"))
    }

    @Test func launchesOnceOnFirstMutationWhenEnabledAndDark() {
        // The canonical case: auto-launch on, no editor yet, first edit.
        #expect(AutoLaunch.shouldLaunch(
            line: call("create_mesh"),
            autoLaunchEnabled: true, editorLive: false, alreadyAttempted: false))
    }

    @Test func doesNotLaunchWhenGatesFail() {
        // --headless disables it.
        #expect(!AutoLaunch.shouldLaunch(
            line: call("create_mesh"),
            autoLaunchEnabled: false, editorLive: false, alreadyAttempted: false))
        // Editor already visible → nothing to launch.
        #expect(!AutoLaunch.shouldLaunch(
            line: call("create_mesh"),
            autoLaunchEnabled: true, editorLive: true, alreadyAttempted: false))
        // Already tried once → never again this session.
        #expect(!AutoLaunch.shouldLaunch(
            line: call("create_mesh"),
            autoLaunchEnabled: true, editorLive: false, alreadyAttempted: true))
        // A read-only call does not trigger the launch even when all else is set.
        #expect(!AutoLaunch.shouldLaunch(
            line: call("query_scene"),
            autoLaunchEnabled: true, editorLive: false, alreadyAttempted: false))
    }
}
