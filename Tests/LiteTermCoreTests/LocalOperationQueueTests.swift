import XCTest
@testable import LiteTermCore

final class LocalOperationQueueTests: XCTestCase {
    @MainActor
    func testWorkspaceSchedulerCoalescesSaturatedNormalIntentsAroundSafetyTransition() async {
        let scheduler = WorkspaceTransitionScheduler()
        let gate = DelayedOperationGate()
        let recorder = OperationRecorder()

        scheduler.submitNormal {
            await recorder.append("normal-running")
            await gate.wait()
        }
        await gate.waitUntilStarted()

        for index in 0..<100 {
            scheduler.submitNormal {
                await recorder.append("normal-\(index)")
            }
        }
        for _ in 0..<100 {
            scheduler.submitSafety {
                await recorder.append("safety")
            }
        }
        scheduler.submitNormal {
            await recorder.append("normal-latest")
        }

        XCTAssertEqual(scheduler.retainedTransitionCount, 3)
        XCTAssertEqual(scheduler.hasPendingSafety, true)
        XCTAssertEqual(scheduler.hasPendingNormal, true)

        await gate.release()
        await scheduler.drain()

        let values = await recorder.values()
        XCTAssertEqual(values, ["normal-running", "safety", "normal-latest"])
        XCTAssertEqual(scheduler.retainedTransitionCount, 0)
    }

    @MainActor
    func testTransitionSuspendsInputAndDrainsOldOperationsBeforeScopeStop() async {
        let queue = LocalOperationQueue()
        let gate = DelayedOperationGate()
        let recorder = OperationRecorder()

        XCTAssertEqual(queue.enqueue {
            await recorder.append("old-start")
            await gate.wait()
            await recorder.append("old-finish")
        }, true)
        XCTAssertEqual(queue.enqueue {
            await recorder.append("old-second")
        }, true)

        let transition = Task { @MainActor in
            await queue.suspendAndDrain()
            await recorder.append("scope-stop")
        }

        await gate.waitUntilStarted()
        while queue.isAccepting {
            await Task.yield()
        }
        XCTAssertEqual(queue.enqueue {
            await recorder.append("blocked")
        }, false)

        await gate.release()
        await transition.value
        let drainedValues = await recorder.values()
        XCTAssertEqual(drainedValues, ["old-start", "old-finish", "old-second", "scope-stop"])

        queue.resume()
        XCTAssertEqual(queue.enqueue {
            await recorder.append("new-root")
        }, true)
        await queue.suspendAndDrain()
        let resumedValues = await recorder.values()
        XCTAssertEqual(resumedValues, ["old-start", "old-finish", "old-second", "scope-stop", "new-root"])
    }

    @MainActor
    func testRepeatedReducerSubmitsStayWithinPendingCountAndCostWhileFirstOperationIsBlocked() async {
        let queue = LocalOperationQueue(maximumPendingOperations: 3, maximumPendingCost: 6)
        let gate = DelayedOperationGate()
        let recorder = OperationRecorder()
        var reducer = LocalTerminalInputReducer()
        var acceptedCount = 0
        var rejectedCount = 0

        for index in 0..<12 {
            let events = reducer.reduce(Array("x\(index % 10)\r".utf8))
            for event in events {
                guard case .submit(let command) = event else { continue }
                let accepted = queue.enqueue(operationCost: command.utf8.count) {
                    if index == 0 {
                        await gate.wait()
                    }
                    await recorder.append(command)
                }
                if accepted {
                    acceptedCount += 1
                } else {
                    rejectedCount += 1
                }
            }
        }

        await gate.waitUntilStarted()
        XCTAssertEqual(acceptedCount, 3)
        XCTAssertEqual(rejectedCount, 9)
        XCTAssertEqual(queue.pendingOperationCount, 3)
        XCTAssertEqual(queue.pendingOperationCost, 6)

        let drain = Task { @MainActor in
            await queue.suspendAndDrain()
        }
        while queue.isAccepting {
            await Task.yield()
        }
        XCTAssertEqual(queue.enqueue(operationCost: 1) {}, false)

        await gate.release()
        await drain.value
        XCTAssertEqual(queue.pendingOperationCount, 0)
        XCTAssertEqual(queue.pendingOperationCost, 0)
        let drainedValues = await recorder.values()
        XCTAssertEqual(drainedValues.count, 3)

        queue.resume()
        XCTAssertEqual(queue.enqueue(operationCost: 6) {
            await recorder.append("resumed")
        }, true)
        await queue.suspendAndDrain()
        XCTAssertEqual(queue.pendingOperationCount, 0)
        XCTAssertEqual(queue.pendingOperationCost, 0)
        let resumedValues = await recorder.values()
        XCTAssertEqual(resumedValues.last, "resumed")
    }
}

private actor DelayedOperationGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor OperationRecorder {
    private var recorded: [String] = []

    func append(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}
