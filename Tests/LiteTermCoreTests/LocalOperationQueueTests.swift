import XCTest
@testable import LiteTermCore

final class LocalOperationQueueTests: XCTestCase {
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
