import Testing
import Foundation
import USDCore
@testable import USDBridge

private func cubeSnapshot() -> StageSnapshot {
    let mesh = Prim(
        path: PrimPath("/Cube")!, typeName: "Mesh",
        attributes: [
            Attribute(name: "points", value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([3])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2])),
        ])
    return StageSnapshot(rootPrims: [mesh])
}

@Suite("StageSaver")
struct StageSaverTests {

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("saver-\(UUID().uuidString).\(ext)")
    }

    @Test func savesUSDAWithoutPython() async throws {
        let url = tempURL("usda")
        defer { try? FileManager.default.removeItem(at: url) }
        try await StageSaver.save(cubeSnapshot(), to: url, executor: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("#usda 1.0"))
        #expect(text.contains("point3f[] points"))
        #expect(text.contains("int[] faceVertexCounts = [3]"))
    }

    @Test func refusesUnsupportedExtension() async {
        await #expect(throws: StageSaver.SaveError.unsupportedExtension("obj")) {
            try await StageSaver.save(cubeSnapshot(), to: tempURL("obj"), executor: nil)
        }
    }

    @Test func binaryFormatsRequirePython() async {
        for ext in ["usdz", "usdc"] {
            await #expect(throws: StageSaver.SaveError.pythonRequired(ext)) {
                try await StageSaver.save(cubeSnapshot(), to: tempURL(ext), executor: nil)
            }
        }
    }

    @Test func saveScriptLivesBesideSnapshotScript() {
        let path = StageSaver.saveScriptPath(near: "/repo/Resources/Python/stage_snapshot.py")
        #expect(path == "/repo/Resources/Python/stage_save.py")
    }

    @Test func usdaSaveIsDeterministic() async throws {
        let a = tempURL("usda"), b = tempURL("usda")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try await StageSaver.save(cubeSnapshot(), to: a, executor: nil)
        try await StageSaver.save(cubeSnapshot(), to: b, executor: nil)
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }
}
