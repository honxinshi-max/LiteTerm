import Foundation

public enum SSHFailureCategory: String, Equatable, Sendable {
    case transport
    case remoteSessionEnded
    case authenticationRejected
    case hostKeyMismatch
    case credentialUnavailable
    case trustCancelled
    case protocolFailure
}

public enum SSHFailureRecovery: Equatable, Sendable {
    case retry
    case reviewHostKey
    case repairCredential
}

public struct SSHFailurePresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let recovery: SSHFailureRecovery

    public init(title: String, message: String, recovery: SSHFailureRecovery) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }

    public var allowsManualRetry: Bool {
        recovery == .retry
    }
}

public extension SSHFailureCategory {
    var presentation: SSHFailurePresentation {
        switch self {
        case .transport:
            return SSHFailurePresentation(
                title: "Connection lost",
                message: "Check the network, host address, and SSH port, then retry.",
                recovery: .retry
            )
        case .remoteSessionEnded:
            return SSHFailurePresentation(
                title: "Remote session ended",
                message: "The remote shell closed the session. Retry to start a new shell.",
                recovery: .retry
            )
        case .authenticationRejected:
            return SSHFailurePresentation(
                title: "Authentication rejected",
                message: "Check the username and saved password or public key, then retry.",
                recovery: .retry
            )
        case .hostKeyMismatch:
            return SSHFailurePresentation(
                title: "Host key changed",
                message: "Do not retry blindly. Verify the server fingerprint before replacing trust.",
                recovery: .reviewHostKey
            )
        case .credentialUnavailable:
            return SSHFailurePresentation(
                title: "Credential unavailable",
                message: "Repair or save the host credential before reconnecting.",
                recovery: .repairCredential
            )
        case .trustCancelled:
            return SSHFailurePresentation(
                title: "Host verification cancelled",
                message: "Open Hosts and reconnect when you are ready to review the fingerprint.",
                recovery: .reviewHostKey
            )
        case .protocolFailure:
            return SSHFailurePresentation(
                title: "SSH protocol error",
                message: "The server rejected an SSH request or used an unsupported protocol path.",
                recovery: .retry
            )
        }
    }
}

public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case awaitingHostTrust
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(SSHFailureCategory)
}

public enum SSHConnectionEvent: Equatable, Sendable {
    case hostKeyValidationRequired
    case hostKeyValidated
    case hostKeyRevalidated
    case authenticationSucceeded
    case reconnecting(attempt: Int)
    case failed(SSHFailureCategory)
}

public struct SSHConnectionStateReducer: Sendable {
    public private(set) var generation: UInt64
    public private(set) var state: SSHConnectionState

    public init() {
        generation = 0
        state = .disconnected
    }

    @discardableResult
    public mutating func beginConnection() -> UInt64 {
        advanceGeneration()
        state = .connecting
        return generation
    }

    @discardableResult
    public mutating func beginReconnect(attempt: Int) -> UInt64 {
        precondition((1...3).contains(attempt), "SSH reconnect attempt must be between 1 and 3")
        advanceGeneration()
        state = .reconnecting(attempt: attempt)
        return generation
    }

    @discardableResult
    public mutating func disconnect() -> UInt64 {
        advanceGeneration()
        state = .disconnected
        return generation
    }

    @discardableResult
    public mutating func beginManualRetry() -> UInt64? {
        guard
            case .failed(let category) = state,
            category.presentation.allowsManualRetry
        else {
            return nil
        }
        advanceGeneration()
        state = .connecting
        return generation
    }

    @discardableResult
    public mutating func reduce(_ event: SSHConnectionEvent, generation: UInt64) -> Bool {
        guard generation == self.generation else {
            return false
        }

        let nextState: SSHConnectionState
        switch (state, event) {
        case (.connecting, .hostKeyValidationRequired),
             (.reconnecting, .hostKeyValidationRequired),
             (.connected, .hostKeyValidationRequired),
             (.awaitingHostTrust, .hostKeyValidationRequired):
            nextState = .awaitingHostTrust

        case (.connecting, .hostKeyValidated),
             (.awaitingHostTrust, .hostKeyValidated),
             (.reconnecting, .hostKeyValidated):
            nextState = .authenticating

        case (.awaitingHostTrust, .hostKeyRevalidated):
            nextState = .connected

        case (.authenticating, .authenticationSucceeded):
            nextState = .connected

        case (.connected, .reconnecting(let attempt)),
             (.connecting, .reconnecting(let attempt)),
             (.authenticating, .reconnecting(let attempt)),
             (.failed(.transport), .reconnecting(let attempt))
            where (1...3).contains(attempt):
            nextState = .reconnecting(attempt: attempt)

        case (.connecting, .failed(let category)),
             (.awaitingHostTrust, .failed(let category)),
             (.authenticating, .failed(let category)),
             (.connected, .failed(let category)),
             (.reconnecting, .failed(let category)),
             (.failed, .failed(let category)):
            nextState = .failed(category)

        default:
            return false
        }

        state = nextState
        return true
    }

    private mutating func advanceGeneration() {
        precondition(generation < UInt64.max, "SSH session generation exhausted")
        generation += 1
    }
}

public struct SSHReconnectDirective: Equatable, Sendable {
    public let attempt: Int
    public let delay: Duration

    public init(attempt: Int, delay: Duration) {
        self.attempt = attempt
        self.delay = delay
    }
}

public struct SSHReconnectOrchestrator: Sendable {
    public private(set) var wantsConnection = false

    private let policy: ReconnectPolicy
    private var sceneIsActive = true
    private var completedAttempts = 0
    private var resumeWhenActive = false

    public init(isEnabled: Bool) {
        policy = ReconnectPolicy(isEnabled: isEnabled)
    }

    public mutating func userInitiatedConnection() {
        wantsConnection = true
        completedAttempts = 0
        resumeWhenActive = false
    }

    public mutating func connectionEstablished() {
        guard wantsConnection else { return }
        completedAttempts = 0
        resumeWhenActive = false
    }

    public mutating func manualDisconnect() {
        cancelConnectionIntent()
    }

    public mutating func connectionFailed(_ failure: SSHConnectionFailure) -> SSHReconnectDirective? {
        switch failure {
        case .authenticationRejected, .hostKeyMismatch, .manualDisconnect:
            cancelConnectionIntent()
            return nil
        case .transportLoss:
            guard wantsConnection else { return nil }
            guard sceneIsActive else {
                resumeWhenActive = true
                completedAttempts = 0
                return nil
            }
            return nextDirective()
        }
    }

    public mutating func scenePhaseChanged(isActive: Bool) -> SSHReconnectDirective? {
        guard sceneIsActive != isActive else { return nil }
        sceneIsActive = isActive

        guard !isActive else {
            guard wantsConnection, resumeWhenActive else { return nil }
            resumeWhenActive = false
            return nextDirective()
        }

        if wantsConnection {
            resumeWhenActive = true
            completedAttempts = 0
        }
        return nil
    }

    private mutating func nextDirective() -> SSHReconnectDirective? {
        guard let delay = policy.nextDelay(
            afterAttempt: completedAttempts,
            failure: .transportLoss,
            sceneIsActive: sceneIsActive
        ) else {
            return nil
        }
        completedAttempts += 1
        return SSHReconnectDirective(attempt: completedAttempts, delay: delay)
    }

    private mutating func cancelConnectionIntent() {
        wantsConnection = false
        completedAttempts = 0
        resumeWhenActive = false
    }
}
