import Testing
import SwiftUI
import USDCore
import DicyaninDesignSystem
@testable import EditorUI

/// Exercises the small overlay/chrome view builders by evaluating `body` across
/// every conditional branch, plus proper assertion tests for the pure logic
/// (`ValueFormatter`, `axisTint`, `axisLabels`, `ColorToken.color`).
@MainActor
@Suite struct OverlayAndChromeViewTests {

    // MARK: ViewportHintOverlay — all three object-mode branches + hidden in edit mode

    @Test func hintOverlayRefusalBranch() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        doc.meshEditRefusal = "Select a mesh to edit."
        _ = ViewportHintOverlay(document: doc).body
    }

    @Test func hintOverlayHintBarBranch() {
        UserDefaults.standard.set(true, forKey: "editor.showHotkeyHints")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = ViewportHintOverlay(document: doc).body
    }

    @Test func hintOverlayDismissedToggleBranch() {
        UserDefaults.standard.set(false, forKey: "editor.showHotkeyHints")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        _ = ViewportHintOverlay(document: doc).body
        UserDefaults.standard.removeObject(forKey: "editor.showHotkeyHints")
    }

    @Test func hintOverlayHiddenInEditMode() {
        let mesh = Prim(
            path: PrimPath("/Root/Panel")!, typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])),
                Attribute(name: "faceVertexCounts", value: .intArray([4])),
                Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
            ])
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
        doc.enterMeshEditMode(at: PrimPath("/Root/Panel")!)
        _ = ViewportHintOverlay(document: doc).body
    }

    // MARK: ImportProgressOverlay — nil, empty, real name

    @Test func importOverlayCoversNameBranches() {
        _ = ImportProgressOverlay(fileName: nil).body
        _ = ImportProgressOverlay(fileName: "").body
        _ = ImportProgressOverlay(fileName: "scene.usdz").body
    }

    // MARK: Styling chrome

    @Test func stylingChromeBodies() {
        _ = Badge("uniform").body
        _ = Badge("err", tint: Palette.error).body
        _ = Card { Text("hi") }.body
        _ = PanelHeader("Title", systemImage: "cube") { Text("x") }.body
        _ = PanelHeader("NoIcon").body
        _ = StatusPill(text: "128 prims").body
        _ = StatusPill(text: "3", tint: Palette.error).body
        _ = FilterField(placeholder: "Filter", text: .constant("")).body
        _ = FilterField(placeholder: "Filter", text: .constant("cube")).body
        _ = PanelSection(title: "Sec") { Text("body") }.body
        _ = FieldRow(label: "Name", value: "Car").body
        _ = FieldRow(label: "Empty", value: "").body
        _ = KeyCap(text: "⇥").body
        _ = HintBar(hints: [Hint(key: "F", label: "Frame")]) {}.body
    }

    @Test func toolbarButtonStyleMakesBodyForBothStates() {
        _ = Button("A") {}.buttonStyle(ToolbarButtonStyle())
        _ = Button("B") {}.buttonStyle(ToolbarButtonStyle(isActive: true))
        // Render the inner style body via a hosting configuration is not possible
        // without a host; constructing the styled button exercises makeBody wiring.
    }

    // MARK: ColorToken.color maps components through

    @Test func colorTokenMapsComponents() {
        let c = Palette.accent.color
        #expect(c != Palette.error.color)
        // A token round-trips its own SwiftUI color deterministically.
        #expect(Palette.accent.color == Palette.accent.color)
    }

    // MARK: ValueFormatter — pure logic, every case

    @Test func valueFormatterCoversEveryCase() {
        #expect(ValueFormatter.string(.bool(true)) == "true")
        #expect(ValueFormatter.string(.bool(false)) == "false")
        #expect(ValueFormatter.string(.int(42)) == "42")
        #expect(ValueFormatter.string(.double(3.0)) == "3")
        #expect(ValueFormatter.string(.double(3.14159)) == "3.142")
        #expect(ValueFormatter.string(.string("hi")) == "\"hi\"")
        #expect(ValueFormatter.string(.token("tok")) == "tok")
        #expect(ValueFormatter.string(.asset("a.png")) == "@a.png@")
        #expect(ValueFormatter.string(.vector([1, 2, 3])) == "(1, 2, 3)")
        #expect(ValueFormatter.string(.matrix4([Double](repeating: 0, count: 16))) == "matrix4d(…)")
        #expect(ValueFormatter.string(.intArray([1, 2])) == "[1, 2]")
        #expect(ValueFormatter.string(.doubleArray([1.0, 2.0])) == "[1, 2]")
        #expect(ValueFormatter.string(.stringArray(["a"])) == "[a]")
        #expect(ValueFormatter.string(.tokenArray(["a", "b"])) == "[a, b]")
        // >6 elements trips the overflow branch.
        #expect(ValueFormatter.string(.intArray(Array(1...10))).contains("+"))
        #expect(ValueFormatter.string(.float3Array([Double](repeating: 0, count: 9))) == "float3[3]")
        #expect(ValueFormatter.string(.quatfArray([Double](repeating: 0, count: 8))) == "quatf[2]")
        #expect(ValueFormatter.string(.matrix4dArray([Double](repeating: 0, count: 32))) == "matrix4d[2]")
        #expect(ValueFormatter.string(.unsupported(typeName: "weird")) == "‹weird›")
    }

    // MARK: axisTint / axisLabels — pure logic

    @Test func axisHelpers() {
        #expect(axisTint(0) == Palette.axisX)
        #expect(axisTint(1) == Palette.axisY)
        #expect(axisTint(2) == Palette.axisZ)
        #expect(axisTint(99) == Palette.axisZ)
        #expect(axisLabels == ["X", "Y", "Z"])
    }

    // MARK: InspectorControls view chrome

    @Test func inspectorControlsBodies() {
        _ = InspectorSection(title: "Sec", subtitle: "3") { Text("c") }.body
        _ = InspectorSection(title: "NoSub") { Text("c") }.body
        // ScrubField with and without a range (fill-bar branch).
        _ = ScrubField(value: 0.5, range: 0...1, step: 0.01) { _ in }.body
        _ = ScrubField(value: 2.0, label: "X", labelTint: Palette.axisX, step: 0.01,
                       suffix: "°") { _ in }.body
        // Zero-span range → frac 0 branch.
        _ = ScrubField(value: 0, range: 1...1) { _ in }.body
        _ = Text("field").sunkenField()
    }
}
