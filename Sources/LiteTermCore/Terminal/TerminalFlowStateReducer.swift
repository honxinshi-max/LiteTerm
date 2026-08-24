import Foundation

public enum TerminalFlowMode: Equatable, Sendable {
    case local
    case ssh
}

public struct TerminalFlowStateReducer: Sendable {
    public private(set) var activeMode: TerminalFlowMode = .local
    public private(set) var activeWorkspaceID: String
    public private(set) var selectedSSHHostID: UUID?
    public private(set) var sshConnectionState: SSHConnectionState = .disconnected
    public private(set) var generation: UInt64 = 0

    private var sshConnectionGeneration: UInt64?

    public init(initialWorkspaceID: String) {
        precondition(!initialWorkspaceID.isEmpty, "A Local workspace identity is required")
        activeWorkspaceID = initialWorkspaceID
    }

    public var activeTerminalSessionCount: Int { 1 }

    public var activeSSHConnectionCount: Int {
        guard sshConnectionGeneration != nil else { return 0 }
        switch sshConnectionState {
        case .disconnected, .failed:
            return 0
        default:
            return 1
        }
    }

    public mutating func selectLocalWorkspace(id: String) {
        precondition(!id.isEmpty, "A Local workspace identity is required")
        activeWorkspaceID = id
        if activeMode == .local {
            advanceGeneration()
        }
    }

    public mutating func selectSSHHost(id: UUID) {
        guard selectedSSHHostID != id else { return }
        selectedSSHHostID = id
        sshConnectionGeneration = nil
        sshConnectionState = .disconnected
    }

    @discardableResult
    public mutating func beginSSHConnection(
        generation: UInt64,
        state: SSHConnectionState
    ) -> Bool {
        guard selectedSSHHostID != nil else { return false }
        switch state {
        case .connecting, .reconnecting:
            break
        default:
            return false
        }

        activeMode = .ssh
        sshConnectionGeneration = generation
        sshConnectionState = state
        advanceGeneration()
        return true
    }

    @discardableResult
    public mutating func updateSSHConnectionState(
        _ state: SSHConnectionState,
        generation: UInt64
    ) -> Bool {
        guard sshConnectionGeneration == generation else { return false }
        sshConnectionState = state
        if state == .disconnected {
            sshConnectionGeneration = nil
        }
        return true
    }

    public func routeRemoteInput(_ bytes: [UInt8]) -> [UInt8]? {
        guard
            activeMode == .ssh,
            sshConnectionGeneration != nil,
            sshConnectionState == .connected,
            !bytes.isEmpty
        else {
            return nil
        }
        return bytes
    }

    public mutating func disconnectSSH() {
        sshConnectionGeneration = nil
        sshConnectionState = .disconnected
        advanceGeneration()
    }

    public mutating func returnToLocal() {
        activeMode = .local
        sshConnectionGeneration = nil
        sshConnectionState = .disconnected
        advanceGeneration()
    }

    private mutating func advanceGeneration() {
        precondition(generation < UInt64.max, "Terminal flow generation exhausted")
        generation += 1
    }
}
