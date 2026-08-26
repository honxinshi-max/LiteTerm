import Foundation
import XCTest
@testable import LiteSpaceCore

final class AcceptanceFlowTests: XCTestCase {
    func testRealLocalSSHLocalFlowModelKeepsOneActiveMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteSpace-Acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        var flow = TerminalFlowStateReducer(initialWorkspaceID: root.path)
        let shell = LocalShell(rootURL: root)

        flow.selectLocalWorkspace(id: root.path)
        XCTAssertEqual(flow.activeMode, .local)
        XCTAssertEqual(flow.activeSSHConnectionCount, 0)

        let touch = await shell.execute("touch draft.txt")
        let initialListing = await shell.execute("ls")
        let emptyContent = await shell.execute("cat draft.txt")
        XCTAssertEqual(touch.outputLines, [])
        XCTAssertEqual(initialListing.outputLines, ["draft.txt"])
        XCTAssertEqual(emptyContent.outputLines, [])

        let edit = await shell.execute("edit draft.txt")
        guard let editorURL = edit.editorURL else {
            return XCTFail("edit must produce a native editor intent")
        }
        try Data("edited on iPad\n".utf8).write(to: editorURL)
        let editedContent = await shell.execute("cat draft.txt")
        XCTAssertEqual(editedContent.outputLines, ["edited on iPad", ""])

        let host = try SSHHost(
            label: "Acceptance Mac",
            hostname: "mac.lan",
            username: "tester",
            authenticationKind: .password,
            reconnectPreference: .enabled
        )
        flow.selectSSHHost(id: host.id)

        var ssh = SSHConnectionStateReducer()
        let sshGeneration = ssh.beginConnection()
        XCTAssertEqual(flow.beginSSHConnection(generation: sshGeneration, state: ssh.state), true)
        XCTAssertEqual(flow.activeMode, .ssh)
        XCTAssertEqual(flow.activeSSHConnectionCount, 1)

        XCTAssertEqual(ssh.reduce(.hostKeyValidated, generation: sshGeneration), true)
        XCTAssertEqual(flow.updateSSHConnectionState(ssh.state, generation: sshGeneration), true)
        XCTAssertEqual(ssh.reduce(.authenticationSucceeded, generation: sshGeneration), true)
        XCTAssertEqual(flow.updateSSHConnectionState(ssh.state, generation: sshGeneration), true)

        let remoteCommand = Array("pwd\r".utf8)
        XCTAssertEqual(flow.routeRemoteInput(remoteCommand), remoteCommand)

        _ = ssh.disconnect()
        flow.disconnectSSH()
        XCTAssertEqual(flow.activeSSHConnectionCount, 0)
        let rejectedRemoteInput: [UInt8]? = flow.routeRemoteInput(remoteCommand)
        XCTAssertNil(rejectedRemoteInput)

        flow.returnToLocal()
        XCTAssertEqual(flow.activeMode, .local)
        XCTAssertEqual(flow.activeSSHConnectionCount, 0)
        let localReturnListing = await shell.execute("ls")
        XCTAssertEqual(localReturnListing.outputLines, ["draft.txt"])
    }
}
