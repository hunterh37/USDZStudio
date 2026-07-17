#if os(macOS)
import Testing
import RealityKit
@testable import ViewportKit

/// The duplicate-name hazard: a USDZ can hold two prims named "Panel" at
/// different depths; lookup must resolve by full path, not first-name-match.
@MainActor
@Suite("Entity prim-path lookup")
struct EntityPathLookupTests {

    /// Root
    ///  └─ (unnamed wrapper, as RealityKit's loader inserts)
    ///      ├─ Rig ─ Panel        (the one we want)
    ///      └─ Backup ─ Panel     (same name, different parent)
    private func makeTree() -> (root: Entity, rigPanel: Entity, backupPanel: Entity) {
        let root = Entity()
        let wrapper = Entity() // loader-inserted, no name
        let rig = Entity(); rig.name = "Rig"
        let backup = Entity(); backup.name = "Backup"
        let rigPanel = Entity(); rigPanel.name = "Panel"
        let backupPanel = Entity(); backupPanel.name = "Panel"
        root.addChild(wrapper)
        wrapper.addChild(backup) // backup first: name-lookup would hit the wrong one
        wrapper.addChild(rig)
        backup.addChild(backupPanel)
        rig.addChild(rigPanel)
        return (root, rigPanel, backupPanel)
    }

    @Test func resolvesTheRightDuplicateByPath() {
        let (root, rigPanel, backupPanel) = makeTree()
        #expect(root.findEntity(primPath: "/Rig/Panel") === rigPanel)
        #expect(root.findEntity(primPath: "/Backup/Panel") === backupPanel)
    }

    @Test func ignoresUnnamedWrapperEntities() {
        let (root, rigPanel, _) = makeTree()
        // The wrapper between root and Rig must not break path matching.
        #expect(root.findEntity(primPath: "/Rig/Panel") === rigPanel)
    }

    @Test func missingPathReturnsNilNotWrongEntity() {
        let (root, _, _) = makeTree()
        #expect(root.findEntity(primPath: "/Rig/Wheel") == nil)
        #expect(root.findEntity(primPath: "/Other/Panel") == nil)
        #expect(root.findEntity(primPath: "") == nil)
    }

    @Test func singleComponentPathMatchesByName() {
        let root = Entity()
        let cube = Entity(); cube.name = "Cube"
        root.addChild(cube)
        #expect(root.findEntity(primPath: "/Cube") === cube)
    }
}
#endif
