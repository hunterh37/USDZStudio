import Testing
import USDCore
@testable import AgentMCP

@Suite("create_joint / set_joint_state tools")
struct JointToolTests {

    @Test func createHingeReturnsPivotAndStates() async {
        let server = Fixtures.server(session: Fixtures.session())
        let result = await callOK(server, "create_joint", [
            "target": "/Root/Lid", "axis": [1, 0, 0], "pivot": [0, 2, -0.5], "openValue": 105,
        ])
        #expect(result["pivotPath"].stringValue == "/Root/Lid_pivot")
        #expect(result["partPath"].stringValue == "/Root/Lid_pivot/Lid")
        #expect(result["states"].arrayValue?.compactMap { $0.stringValue } == ["closed", "open"])
    }

    @Test func createPrismaticSlider() async {
        let server = Fixtures.server(session: Fixtures.session())
        let result = await callOK(server, "create_joint", [
            "target": "/Root/Lid", "kind": "prismatic", "axis": [0, 0, 1], "pivot": [0, 0, 0], "openValue": 2,
        ])
        #expect(result["pivotPath"].stringValue == "/Root/Lid_pivot")
    }

    @Test func createJointRejectsBadArgs() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callError(server, "create_joint",
                            ["target": "/Root/Lid", "axis": [1, 0], "pivot": [0, 0, 0], "openValue": 90])
        _ = await callError(server, "create_joint",
                            ["target": "/Root/Lid", "axis": [1, 0, 0], "pivot": [0, 0], "openValue": 90])
        _ = await callError(server, "create_joint",
                            ["target": "/Root/Lid", "axis": [1, 0, 0], "pivot": [0, 0, 0]])
        // Degenerate axis fails joint validation inside the command.
        _ = await callError(server, "create_joint",
                            ["target": "/Root/Lid", "axis": [0, 0, 0], "pivot": [0, 0, 0], "openValue": 90])
    }

    @Test func setJointStateOpensViaPivotAndPart() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "create_joint",
                         ["target": "/Root/Lid", "axis": [1, 0, 0], "pivot": [0, 2, -0.5], "openValue": 105])
        // By pivot path + state name.
        _ = await callOK(server, "set_joint_state", ["target": "/Root/Lid_pivot", "state": "open"])
        // By the moving part's path (resolves up to the pivot) + explicit value.
        _ = await callOK(server, "set_joint_state", ["target": "/Root/Lid_pivot/Lid", "value": 30])
        // Back to closed.
        _ = await callOK(server, "set_joint_state", ["target": "/Root/Lid_pivot", "state": "closed"])
    }

    @Test func setJointStateRejectsBadInput() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "create_joint",
                         ["target": "/Root/Lid", "axis": [1, 0, 0], "pivot": [0, 2, -0.5], "openValue": 105])
        _ = await callError(server, "set_joint_state", ["target": "/Root/Lid_pivot", "state": "ajar"])
        _ = await callError(server, "set_joint_state", ["target": "/Root/Lid_pivot", "value": 999])
        _ = await callError(server, "set_joint_state", ["target": "/Root/Lid_pivot"])
        // A prim that is neither a pivot nor a part under one.
        _ = await callError(server, "set_joint_state", ["target": "/Root/Box", "state": "open"])
    }
}
