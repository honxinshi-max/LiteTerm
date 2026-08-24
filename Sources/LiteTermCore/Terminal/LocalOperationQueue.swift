@MainActor
public final class LocalOperationQueue {
    private var tail: Task<Void, Never> = Task {}

    public private(set) var isAccepting = true

    public init() {}

    @discardableResult
    public func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        guard isAccepting else { return false }

        let previous = tail
        tail = Task {
            await previous.value
            await operation()
        }
        return true
    }

    public func suspendAndDrain() async {
        isAccepting = false
        let pending = tail
        await pending.value
    }

    public func resume() {
        isAccepting = true
    }
}
