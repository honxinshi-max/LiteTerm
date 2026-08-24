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
