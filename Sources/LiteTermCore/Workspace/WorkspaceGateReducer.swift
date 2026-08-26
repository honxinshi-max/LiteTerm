import Foundation

public enum WorkspaceFailureCategory: String, Codable, CaseIterable, Sendable {
    case inspect
    case check
    case test
    case start
    case health
    case runtime
    case resource
    case privacy
    case unsupported
    case cancelled
}

public enum WorkspaceGateState: Equatable, Sendable {
    case idle
    case inspecting
    case checking
    case checked
    case testing
    case starting
    case completed
    case healthChecking(successes: Int)
    case ready(ReadyPortLease)
    case failed(WorkspaceFailureCategory)
    case stopping
}

public enum WorkspaceGateEvent: Equatable, Sendable {
    case inspectionPassed
    case checkPassed
    case checkOnlyCompleted
    case testsPassed
    case serviceStarted(port: Int, listenerID: UUID, runtimeID: UUID, secretHandle: UUID)
    case scriptCompleted
    case healthSucceeded(expiresAt: Date)
    case healthFailed(WorkspaceFailureCategory)
    case failed(WorkspaceFailureCategory)
    case listenerClosed
    case runtimeExited
    case stopRequested
    case stopped
}

public struct WorkspaceGateReducer: Sendable {
    public private(set) var generation: UInt64
    public private(set) var state: WorkspaceGateState

    private var listenerID: UUID?
    private var runtimeID: UUID?
    private var secretHandle: UUID?
    private var pendingPort: Int?
    private var listenerIsActive = false
    private var runtimeIsAlive = false
    private let leasePolicy = ReadyPortLeasePolicy()

    public init(generation: UInt64 = 0, state: WorkspaceGateState = .idle) {
        self.generation = generation
        self.state = state
        if case let .ready(lease) = state, lease.generation == generation {
            listenerID = lease.listenerID
            runtimeID = lease.runtimeID
            secretHandle = lease.secretHandle
            pendingPort = lease.port
            listenerIsActive = true
            runtimeIsAlive = true
        }
    }

    public var publishedPort: Int? {
        publishedPort(at: Date())
    }

    public func publishedPort(at now: Date) -> Int? {
        guard case let .ready(lease) = state else { return nil }
        return leasePolicy.isPublishable(
            lease,
            currentGeneration: generation,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: listenerIsActive,
            runtimeIsAlive: runtimeIsAlive,
            now: now
        ) ? lease.port : nil
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        advanceGeneration()
        clearServiceState()
        state = .inspecting
        return generation
    }

    @discardableResult
    public mutating func invalidate() -> UInt64 {
        advanceGeneration()
        clearServiceState()
        state = .idle
        return generation
    }

    @discardableResult
    public mutating func reduce(
        _ event: WorkspaceGateEvent,
        generation eventGeneration: UInt64,
        now: Date
    ) -> Bool {
        guard eventGeneration == generation else { return false }

        switch event {
        case .inspectionPassed:
            guard state == .inspecting else { return false }
            state = .checking
        case .checkPassed:
            guard state == .checking else { return false }
            state = .testing
        case .checkOnlyCompleted:
            guard state == .checking else { return false }
            clearServiceState()
            state = .checked
        case .testsPassed:
            guard state == .testing else { return false }
            state = .starting
        case let .serviceStarted(port, newListenerID, newRuntimeID, newSecretHandle):
            guard state == .starting, (1...65_535).contains(port) else { return false }
            pendingPort = port
            listenerID = newListenerID
            runtimeID = newRuntimeID
            secretHandle = newSecretHandle
            listenerIsActive = true
            runtimeIsAlive = true
            state = .healthChecking(successes: 0)
        case .scriptCompleted:
            guard state == .starting else { return false }
            clearServiceState()
            state = .completed
        case let .healthSucceeded(expiresAt):
            guard expiresAt > now else { return false }
            switch state {
            case let .healthChecking(successes):
                guard
                    listenerIsActive,
                    runtimeIsAlive,
                    let pendingPort,
                    let listenerID,
                    let runtimeID,
                    let secretHandle
                else {
                    return false
                }
                let nextSuccesses = successes + 1
                if nextSuccesses < RuntimeResourceBudget.iPadCandidate.healthSuccessCount {
                    state = .healthChecking(successes: nextSuccesses)
                } else {
                    state = .ready(ReadyPortLease(
                        generation: generation,
                        port: pendingPort,
                        listenerID: listenerID,
                        runtimeID: runtimeID,
                        secretHandle: secretHandle,
                        healthExpiresAt: expiresAt
                    ))
                }
            case let .ready(lease):
                guard publishedPort(at: now) != nil else { return false }
                state = .ready(ReadyPortLease(
                    generation: lease.generation,
                    port: lease.port,
                    listenerID: lease.listenerID,
                    runtimeID: lease.runtimeID,
                    secretHandle: lease.secretHandle,
                    healthExpiresAt: expiresAt
                ))
            default:
                return false
            }
        case let .healthFailed(category):
            guard isHealthOrReady else { return false }
            clearServiceState()
            state = .failed(category)
        case let .failed(category):
            guard isActiveState else { return false }
            clearServiceState()
            state = .failed(category)
        case .listenerClosed:
            guard isHealthOrReady else { return false }
            clearServiceState()
            state = .failed(.runtime)
        case .runtimeExited:
            guard isRuntimeState else { return false }
            clearServiceState()
            state = .failed(.runtime)
        case .stopRequested:
            guard state != .idle, state != .stopping else { return false }
            clearServiceState()
            state = .stopping
        case .stopped:
            guard state == .stopping else { return false }
            clearServiceState()
            state = .idle
        }
        return true
    }

    private var isActiveState: Bool {
        switch state {
        case .inspecting, .checking, .testing, .starting, .healthChecking, .ready:
            return true
        case .idle, .checked, .completed, .failed, .stopping:
            return false
        }
    }

    private var isHealthOrReady: Bool {
        switch state {
        case .healthChecking, .ready:
            return true
        default:
            return false
        }
    }

    private var isRuntimeState: Bool {
        switch state {
        case .checking, .testing, .starting, .healthChecking, .ready:
            return true
        default:
            return false
        }
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }

    private mutating func clearServiceState() {
        pendingPort = nil
        listenerID = nil
        runtimeID = nil
        secretHandle = nil
        listenerIsActive = false
        runtimeIsAlive = false
    }
}
