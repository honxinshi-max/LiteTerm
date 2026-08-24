@MainActor
public final class LocalOperationQueue {
    public static let defaultMaximumPendingOperations = 16
    public static let defaultMaximumPendingCost = 64 * 1024

    private let maximumPendingOperations: Int
    private let maximumPendingCost: Int
    private var tail: Task<Void, Never> = Task {}
    private var activeDrainCount = 0
    private var resumeRequested = false

    public private(set) var isAccepting = true
    public private(set) var pendingOperationCount = 0
    public private(set) var pendingOperationCost = 0

    public init(
        maximumPendingOperations: Int = LocalOperationQueue.defaultMaximumPendingOperations,
        maximumPendingCost: Int = LocalOperationQueue.defaultMaximumPendingCost
    ) {
        self.maximumPendingOperations = max(0, maximumPendingOperations)
        self.maximumPendingCost = max(0, maximumPendingCost)
    }

    @discardableResult
    public func enqueue(
        operationCost: Int = 0,
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        guard
            isAccepting,
            operationCost >= 0,
            pendingOperationCount < maximumPendingOperations,
            operationCost <= maximumPendingCost - pendingOperationCost
        else { return false }

        pendingOperationCount += 1
        pendingOperationCost += operationCost
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous.value
            await operation()
            self?.completeOperation(cost: operationCost)
        }
        return true
    }

    public func suspendAndDrain() async {
        isAccepting = false
        activeDrainCount += 1
        let pending = tail
        await pending.value
        activeDrainCount -= 1
        if activeDrainCount == 0, resumeRequested {
            resumeRequested = false
            isAccepting = true
        }
    }

    public func resume() {
        guard activeDrainCount == 0 else {
            resumeRequested = true
            return
        }
        isAccepting = true
    }

    private func completeOperation(cost: Int) {
        pendingOperationCount -= 1
        pendingOperationCost -= cost
    }
}

/// Serializes workspace-root transitions without retaining an unbounded closure chain.
///
/// At most one transition runs while one safety transition and the latest normal
/// transition wait. Safety work is always selected before normal work.
@MainActor
public final class WorkspaceTransitionScheduler {
    public typealias Operation = @Sendable () async -> Void

    private var runningTask: Task<Void, Never>?
    private var pendingSafety: Operation?
    private var pendingNormal: Operation?

    public init() {}

    public var hasPendingSafety: Bool { pendingSafety != nil }
    public var hasPendingNormal: Bool { pendingNormal != nil }
    public var retainedTransitionCount: Int {
        (runningTask == nil ? 0 : 1) + (pendingSafety == nil ? 0 : 1) + (pendingNormal == nil ? 0 : 1)
    }

    public func submitNormal(_ operation: @escaping Operation) {
        submit(operation, safety: false)
    }

    public func submitSafety(_ operation: @escaping Operation) {
        submit(operation, safety: true)
    }

    public func drain() async {
        while let task = runningTask {
            await task.value
        }
    }

    private func submit(_ operation: @escaping Operation, safety: Bool) {
        guard runningTask != nil else {
            start(operation)
            return
        }
        if safety {
            pendingSafety = operation
        } else {
            pendingNormal = operation
        }
    }

    private func start(_ operation: @escaping Operation) {
        runningTask = Task { @MainActor [weak self] in
            await operation()
            self?.advance()
        }
    }

    private func advance() {
        runningTask = nil
        if let safety = pendingSafety {
            pendingSafety = nil
            start(safety)
        } else if let normal = pendingNormal {
            pendingNormal = nil
            start(normal)
        }
    }
}
