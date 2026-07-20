import Testing
import USDCore
@testable import EditingKit

private func p(_ s: String) -> PrimPath { PrimPath(s)! }

private func stage() -> InMemoryStage {
    let bolt = Prim(path: p("/Car/Bolt"), typeName: "Mesh")
    let hidden = Prim(path: p("/Car/Trim"), typeName: "Mesh", visibility: .invisible)
    let off = Prim(path: p("/Car/Spare"), typeName: "Mesh", isActive: false)
    let car = Prim(path: p("/Car"), typeName: "Xform", children: [bolt, hidden, off])
    return InMemoryStage(StageSnapshot(rootPrims: [car]))
}

@Suite("PartEditKind descriptors")
struct PartEditDescriptorTests {

    @Test func allThreeKindsHaveDistinctCopyAndIcons() {
        let kinds = PartEditKind.allCases
        #expect(kinds == [.hide, .disable, .delete])
        #expect(Set(kinds.map(\.systemImage)).count == 3)
        #expect(Set(kinds.map(\.help)).count == 3)
        #expect(kinds.allSatisfy { !$0.help.isEmpty })
    }

    @Test func onlyDeleteIsDestructive() {
        #expect(PartEditKind.delete.isDestructive)
        #expect(!PartEditKind.hide.isDestructive)
        #expect(!PartEditKind.disable.isDestructive)
    }

    @Test func rawValuesStable() {
        #expect(PartEditKind.hide.rawValue == "hide")
        #expect(PartEditKind.disable.rawValue == "disable")
        #expect(PartEditKind.delete.rawValue == "delete")
    }

    @Test func titlesAndStateReflectVisibleActivePrim() {
        let prim = Prim(path: p("/Car/Bolt"), typeName: "Mesh")
        #expect(PartEditKind.hide.title(for: prim) == "Hide")
        #expect(PartEditKind.disable.title(for: prim) == "Disable")
        #expect(PartEditKind.delete.title(for: prim) == "Delete")
        #expect(PartEditKind.allCases.allSatisfy { !$0.isEngaged(for: prim) })
    }

    @Test func titlesFlipForHiddenAndDisabled() {
        let hidden = Prim(path: p("/Car/Trim"), typeName: "Mesh", visibility: .invisible)
        #expect(PartEditKind.hide.title(for: hidden) == "Show")
        #expect(PartEditKind.hide.isEngaged(for: hidden))

        let off = Prim(path: p("/Car/Spare"), typeName: "Mesh", isActive: false)
        #expect(PartEditKind.disable.title(for: off) == "Enable")
        #expect(PartEditKind.disable.isEngaged(for: off))
    }

    @Test func controlUsesEngagedIconWhenEngaged() {
        let hidden = Prim(path: p("/Car/Trim"), typeName: "Mesh", visibility: .invisible)
        let control = PartEditKind.hide.control(for: hidden)
        #expect(control.isEngaged)
        #expect(control.systemImage == PartEditKind.hide.engagedSystemImage)
        #expect(control.id == .hide)

        let bolt = Prim(path: p("/Car/Bolt"), typeName: "Mesh")
        #expect(PartEditKind.hide.control(for: bolt).systemImage == PartEditKind.hide.systemImage)
    }

    @Test func controlsReturnsTrioInOrder() {
        let controls = PartEditKind.controls(for: Prim(path: p("/Car/Bolt"), typeName: "Mesh"))
        #expect(controls.map(\.kind) == [.hide, .disable, .delete])
        // delete keeps its icon whether or not it could ever be "engaged"
        #expect(PartEditKind.delete.engagedSystemImage == "trash")
    }
}

@Suite("PartEditCommandFactory")
struct PartEditCommandFactoryTests {

    @Test func hideTogglesVisibility() throws {
        let s = stage()
        let cmd = try #require(PartEditCommandFactory.command(.hide, for: p("/Car/Bolt"), in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: p("/Car/Bolt"))?.visibility == .invisible)

        // Toggling an already-hidden prim shows it.
        let show = try #require(PartEditCommandFactory.command(.hide, for: p("/Car/Trim"), in: s))
        try show.execute(on: s)
        #expect(s.prim(at: p("/Car/Trim"))?.visibility == .inherited)
    }

    @Test func disableTogglesActive() throws {
        let s = stage()
        let cmd = try #require(PartEditCommandFactory.command(.disable, for: p("/Car/Bolt"), in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: p("/Car/Bolt"))?.isActive == false)

        let enable = try #require(PartEditCommandFactory.command(.disable, for: p("/Car/Spare"), in: s))
        try enable.execute(on: s)
        #expect(s.prim(at: p("/Car/Spare"))?.isActive == true)
    }

    @Test func deleteRemovesAndUndoRestores() throws {
        let s = stage()
        let cmd = try #require(PartEditCommandFactory.command(.delete, for: p("/Car/Bolt"), in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: p("/Car/Bolt")) == nil)
        try cmd.undo(on: s)
        #expect(s.prim(at: p("/Car/Bolt")) != nil)
    }

    @Test func returnsNilForMissingPrim() {
        let s = stage()
        #expect(PartEditCommandFactory.command(.hide, for: p("/Nope"), in: s) == nil)
        #expect(PartEditCommandFactory.command(.delete, for: p("/Nope"), in: s) == nil)
    }
}
