import Foundation
import XCTest
@testable import LiteSpaceCore

final class WorkspaceGateReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testServicePortAppearsOnlyAfterThirdCurrentHealthSuccess() {
        var gate = WorkspaceGateReducer()
        let generation = gate.begin()
        let listenerID = UUID()
        let runtimeID = UUID()
        let secretHandle = UUID()

        XCTAssertEqual(gate.state, .inspecting)
        XCTAssertNil(gate.publishedPort(at: now))
        XCTAssertTrue(gate.reduce(.inspectionPassed, generation: generation, now: now))
        XCTAssertEqual(gate.state, .checking)
        XCTAssertNil(gate.publishedPort(at: now))
        XCTAssertTrue(gate.reduce(.checkPassed, generation: generation, now: now))
        XCTAssertEqual(gate.state, .testing)
        XCTAssertNil(gate.publishedPort(at: now))
        XCTAssertTrue(gate.reduce(.testsPassed, generation: generation, now: now))
        XCTAssertEqual(gate.state, .starting)
        XCTAssertNil(gate.publishedPort(at: now))
        XCTAssertTrue(gate.reduce(
            .serviceStarted(
                port: 49152,
                listenerID: listenerID,
                runtimeID: runtimeID,
                secretHandle: secretHandle
            ),
            generation: generation,
            now: now
        ))
        XCTAssertEqual(gate.state, .healthChecking(successes: 0))
        XCTAssertNil(gate.publishedPort(at: now))

        for successes in 1...2 {
            XCTAssertTrue(gate.reduce(
                .healthSucceeded(expiresAt: now.addingTimeInterval(5)),
                generation: generation,
                now: now
            ))
            XCTAssertEqual(gate.state, .healthChecking(successes: successes))
            XCTAssertNil(gate.publishedPort(at: now))
        }

        XCTAssertTrue(gate.reduce(
            .healthSucceeded(expiresAt: now.addingTimeInterval(5)),
            generation: generation,
            now: now
        ))
        XCTAssertEqual(gate.publishedPort(at: now), 49152)
        guard case let .ready(lease) = gate.state else {
            return XCTFail("Third health success must create a Ready lease")
        }
        XCTAssertEqual(lease.generation, generation)
        XCTAssertEqual(lease.listenerID, listenerID)
        XCTAssertEqual(lease.runtimeID, runtimeID)
        XCTAssertEqual(lease.secretHandle, secretHandle)
    }

    func testCheckOnlyAndScriptCompletionNeverPublishPort() {
        var checked = WorkspaceGateReducer()
        let checkedGeneration = checked.begin()
        XCTAssertTrue(checked.reduce(.inspectionPassed, generation: checkedGeneration, now: now))
        XCTAssertTrue(checked.reduce(.checkOnlyCompleted, generation: checkedGeneration, now: now))
        XCTAssertEqual(checked.state, .checked)
        XCTAssertNil(checked.publishedPort(at: now))

        var tested = WorkspaceGateReducer()
        let testedGeneration = tested.begin()
        XCTAssertTrue(tested.reduce(.inspectionPassed, generation: testedGeneration, now: now))
        XCTAssertTrue(tested.reduce(.checkPassed, generation: testedGeneration, now: now))
        XCTAssertTrue(tested.reduce(.testOnlyCompleted, generation: testedGeneration, now: now))
        XCTAssertEqual(tested.state, .checked)
        XCTAssertNil(tested.publishedPort(at: now))

        var completed = WorkspaceGateReducer()
        let completedGeneration = completed.begin()
        XCTAssertTrue(completed.reduce(.inspectionPassed, generation: completedGeneration, now: now))
        XCTAssertTrue(completed.reduce(.checkPassed, generation: completedGeneration, now: now))
        XCTAssertTrue(completed.reduce(.testsPassed, generation: completedGeneration, now: now))
        XCTAssertTrue(completed.reduce(.scriptCompleted, generation: completedGeneration, now: now))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertNil(completed.publishedPort(at: now))
    }

    func testStaleGenerationCannotChangeStateOrPublishPort() {
        var gate = WorkspaceGateReducer()
        let stale = gate.begin()
        let current = gate.invalidate()

        XCTAssertFalse(gate.reduce(.inspectionPassed, generation: stale, now: now))
        XCTAssertEqual(gate.generation, current)
        XCTAssertEqual(gate.state, .idle)
        XCTAssertNil(gate.publishedPort(at: now))
    }

    func testInvalidationRuntimeExitAndHealthFailureWithdrawReadyPort() {
        var invalidated = readyGate(now: now)
        _ = invalidated.invalidate()
        XCTAssertEqual(invalidated.state, .idle)
        XCTAssertNil(invalidated.publishedPort(at: now))

        var exited = readyGate(now: now)
        let exitGeneration = exited.generation
        XCTAssertTrue(exited.reduce(.runtimeExited, generation: exitGeneration, now: now))
        XCTAssertEqual(exited.state, .failed(.runtime))
        XCTAssertNil(exited.publishedPort(at: now))

        var unhealthy = readyGate(now: now)
        let healthGeneration = unhealthy.generation
        XCTAssertTrue(unhealthy.reduce(
            .healthFailed(.health),
            generation: healthGeneration,
            now: now
        ))
        XCTAssertEqual(unhealthy.state, .failed(.health))
        XCTAssertNil(unhealthy.publishedPort(at: now))
    }

    func testStopTransitionsThroughStoppingAndClearsLease() {
        var gate = readyGate(now: now)
        let generation = gate.generation

        XCTAssertTrue(gate.reduce(.stopRequested, generation: generation, now: now))
        XCTAssertEqual(gate.state, .stopping)
        XCTAssertNil(gate.publishedPort(at: now))
        XCTAssertTrue(gate.reduce(.stopped, generation: generation, now: now))
        XCTAssertEqual(gate.state, .idle)
    }

    private func readyGate(now: Date) -> WorkspaceGateReducer {
        var gate = WorkspaceGateReducer()
        let generation = gate.begin()
        _ = gate.reduce(.inspectionPassed, generation: generation, now: now)
        _ = gate.reduce(.checkPassed, generation: generation, now: now)
        _ = gate.reduce(.testsPassed, generation: generation, now: now)
        _ = gate.reduce(
            .serviceStarted(
                port: 49152,
                listenerID: UUID(),
                runtimeID: UUID(),
                secretHandle: UUID()
            ),
            generation: generation,
            now: now
        )
        for _ in 0..<3 {
            _ = gate.reduce(
                .healthSucceeded(expiresAt: now.addingTimeInterval(5)),
                generation: generation,
                now: now
            )
        }
        return gate
    }
}
