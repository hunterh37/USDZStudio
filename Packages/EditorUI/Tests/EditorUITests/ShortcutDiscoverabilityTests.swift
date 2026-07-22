import Testing
import Foundation
import SwiftUI
import ViewportKit
@testable import EditorUI

// MARK: - Registry

@Suite("ShortcutRegistry — single source of truth")
struct ShortcutRegistryTests {

    @Test func everyGroupNonEmpty() {
        for group in ShortcutGroup.allCases {
            #expect(!(ShortcutRegistry.groups[group] ?? []).isEmpty, "\(group) empty")
        }
    }

    @Test func keysUniqueWithinGroup() {
        for (_, shortcuts) in ShortcutRegistry.orderedGroups {
            let keys = shortcuts.map(\.keys)
            #expect(Set(keys).count == keys.count)
        }
    }

    @Test func everyGizmoModeHasEntry() {
        // W/E/R gizmo modes each appear in the gizmo group.
        let gizmoKeys = Set((ShortcutRegistry.groups[.transformGizmo] ?? []).map { $0.keys.lowercased() })
        for mode in GizmoMode.allCases {
            #expect(gizmoKeys.contains(String(mode.shortcut)))
        }
    }

    @Test func everyModalKindHasEntry() {
        let modalKeys = Set((ShortcutRegistry.groups[.transformModal] ?? []).map { $0.keys.lowercased() })
        #expect(modalKeys.contains("g"))
        #expect(modalKeys.contains("r"))
        #expect(modalKeys.contains("s"))
    }

    @Test func orderedGroupsMatchAllCases() {
        #expect(ShortcutRegistry.orderedGroups.map(\.group) == ShortcutGroup.allCases)
    }

    @Test func flattenedAllIncludesEveryShortcut() {
        let total = ShortcutRegistry.groups.values.reduce(0) { $0 + $1.count }
        #expect(ShortcutRegistry.all.count == total)
        #expect(ShortcutRegistry.all.allSatisfy { !$0.id.isEmpty })
    }

    @Test func groupMetadata() {
        #expect(ShortcutGroup.camera.title == "Camera")
        #expect(ShortcutGroup.camera.id == "Camera")
        #expect(!ShortcutRegistry.hintLine.isEmpty)
        // group is stamped onto each shortcut
        #expect(ShortcutRegistry.groups[.camera]?.allSatisfy { $0.group == .camera } == true)
    }
}

// MARK: - Hint controller

@MainActor
private final class FakePrefs: HintPreferenceStore {
    var showHotkeyHints: Bool
    init(_ v: Bool = true) { showHotkeyHints = v }
}

@MainActor
@Suite("ShortcutHintController — show/hold/fade state machine")
struct ShortcutHintControllerTests {

    private let fi = ShortcutHintController.fadeIn
    private let hold = ShortcutHintController.hold
    private let fo = ShortcutHintController.fadeOut

    @Test func hiddenUntilSceneAppears() {
        let c = ShortcutHintController(preferences: FakePrefs())
        #expect(!c.isVisible)
        #expect(c.phase == .hidden)
        c.tick(now: 5)                 // tick with no session is a no-op
        #expect(!c.isVisible)
    }

    @Test func fadeInHoldFadeOutCycle() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onSceneAppear(now: 0)
        #expect(c.phase == .fadingIn)
        c.tick(now: fi / 2)
        #expect(c.phase == .fadingIn)
        #expect(abs(c.opacity - 0.5) < 1e-6)
        c.tick(now: fi + hold / 2)
        #expect(c.phase == .holding)
        #expect(c.opacity == 1)
        c.tick(now: fi + hold + fo / 2)
        #expect(c.phase == .fadingOut)
        #expect(abs(c.opacity - 0.5) < 1e-6)
        c.tick(now: fi + hold + fo + 1)
        #expect(c.phase == .hidden)
        #expect(c.opacity == 0)
        #expect(!c.isVisible)
    }

    @Test func negativeElapsedClampsToZero() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onSceneAppear(now: 10)
        c.tick(now: 9)                 // clock ran backward
        #expect(c.opacity == 0)
        #expect(c.phase == .fadingIn)
    }

    @Test func interactionDismissesEarly() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onSceneAppear(now: 0)
        c.tick(now: fi + 0.1)
        #expect(c.isVisible)
        c.onInteraction()
        #expect(!c.isVisible)
        #expect(c.opacity == 0)
        // A later tick stays hidden (session consumed).
        c.tick(now: fi + 0.2)
        #expect(!c.isVisible)
    }

    @Test func interactionBeforeVisibleIsNoOp() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onInteraction()              // nothing showing
        #expect(!c.isVisible)
    }

    @Test func oncePerSession() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onSceneAppear(now: 0)
        c.tick(now: fi + hold + fo + 1)   // run to completion
        #expect(!c.isVisible)
        c.onSceneAppear(now: 100)          // second scene appear does nothing
        #expect(!c.isVisible)
        #expect(c.phase == .hidden)
    }

    @Test func resetSessionAllowsShowingAgain() {
        let c = ShortcutHintController(preferences: FakePrefs())
        c.onSceneAppear(now: 0)
        c.resetSession()
        #expect(!c.isVisible)
        c.onSceneAppear(now: 50)
        #expect(c.isVisible)
    }

    @Test func suppressedPreferenceBlocksAppearance() {
        let c = ShortcutHintController(preferences: FakePrefs(false))
        c.onSceneAppear(now: 0)
        #expect(!c.isVisible)
    }

    @Test func dismissForeverPersistsAndHides() {
        let prefs = FakePrefs(true)
        let c = ShortcutHintController(preferences: prefs)
        c.onSceneAppear(now: 0)
        c.tick(now: fi)
        c.dismissForever()
        #expect(prefs.showHotkeyHints == false)
        #expect(!c.isVisible)
    }

    @Test func worksWithoutPreferences() {
        let c = ShortcutHintController(preferences: nil)  // no store injected
        c.onSceneAppear(now: 0)
        #expect(c.isVisible)
        c.dismissForever()             // no store: still hides
        #expect(!c.isVisible)
    }

    @Test func textFromRegistry() {
        let c = ShortcutHintController()
        #expect(c.text == ShortcutRegistry.hintLine)
    }
}

// MARK: - View bodies (branch coverage; logic asserted above)

@MainActor
@Suite("Discoverability views — body evaluation")
struct ShortcutViewBodyTests {

    @Test func shortcutsOverlayBody() {
        _ = ShortcutsOverlay(isPresented: .constant(true)).body
    }

    @Test func hintToastBodies() {
        let visible = ShortcutHintController(preferences: FakePrefs())
        visible.onSceneAppear(now: 0)
        visible.tick(now: ShortcutHintController.fadeIn)
        _ = ShortcutHintToast(controller: visible).body

        let hidden = ShortcutHintController(preferences: FakePrefs(false))
        _ = ShortcutHintToast(controller: hidden).body
    }
}
