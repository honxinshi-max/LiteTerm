import XCTest
@testable import LiteTermCore

final class ReconnectPolicyTests: XCTestCase {
    func testTransportLossUsesExactlyThreeBoundedDelays() {
        let policy = ReconnectPolicy(isEnabled: true)

        let delays = (0...3).map {
            policy.nextDelay(
                afterAttempt: $0,
                failure: .transportLoss,
                sceneIsActive: true
            )
        }

        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4), nil])
    }

    func testInactiveSceneNeverRetries() {
        let policy = ReconnectPolicy(isEnabled: true)

        XCTAssertNil(
            policy.nextDelay(
                afterAttempt: 0,
                failure: .transportLoss,
                sceneIsActive: false
            )
        )
    }

    func testDisabledHostNeverRetries() {
        let policy = ReconnectPolicy(isEnabled: false)

        XCTAssertNil(
            policy.nextDelay(
                afterAttempt: 0,
                failure: .transportLoss,
                sceneIsActive: true
            )
        )
    }

    func testAuthenticationAndHostKeyFailuresNeverRetry() {
        let policy = ReconnectPolicy(isEnabled: true)

        XCTAssertNil(policy.nextDelay(afterAttempt: 0, failure: .authenticationRejected, sceneIsActive: true))
        XCTAssertNil(policy.nextDelay(afterAttempt: 0, failure: .hostKeyMismatch, sceneIsActive: true))
    }

    func testManualDisconnectNeverRetries() {
        let policy = ReconnectPolicy(isEnabled: true)

        XCTAssertNil(policy.nextDelay(afterAttempt: 0, failure: .manualDisconnect, sceneIsActive: true))
    }

    func testNegativeAttemptNeverRetries() {
        let policy = ReconnectPolicy(isEnabled: true)

        XCTAssertNil(policy.nextDelay(afterAttempt: -1, failure: .transportLoss, sceneIsActive: true))
    }
}
