import Foundation
import XCTest
@testable import LiteSpaceCore

final class ReadyPortLeasePolicyTests: XCTestCase {
    func testLeaseRequiresCurrentGenerationMatchingLiveIdentitiesAndFutureExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let listenerID = UUID()
        let runtimeID = UUID()
        let lease = ReadyPortLease(
            generation: 4,
            port: 49152,
            listenerID: listenerID,
            runtimeID: runtimeID,
            secretHandle: UUID(),
            healthExpiresAt: now.addingTimeInterval(1)
        )
        let policy = ReadyPortLeasePolicy()

        XCTAssertTrue(policy.isPublishable(
            lease,
            currentGeneration: 4,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: true,
            runtimeIsAlive: true,
            now: now
        ))
        XCTAssertFalse(policy.isPublishable(
            lease,
            currentGeneration: 5,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: true,
            runtimeIsAlive: true,
            now: now
        ))
        XCTAssertFalse(policy.isPublishable(
            lease,
            currentGeneration: 4,
            listenerID: UUID(),
            runtimeID: runtimeID,
            listenerIsActive: true,
            runtimeIsAlive: true,
            now: now
        ))
        XCTAssertFalse(policy.isPublishable(
            lease,
            currentGeneration: 4,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: false,
            runtimeIsAlive: true,
            now: now
        ))
        XCTAssertFalse(policy.isPublishable(
            lease,
            currentGeneration: 4,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: true,
            runtimeIsAlive: false,
            now: now
        ))
        XCTAssertFalse(policy.isPublishable(
            lease,
            currentGeneration: 4,
            listenerID: listenerID,
            runtimeID: runtimeID,
            listenerIsActive: true,
            runtimeIsAlive: true,
            now: lease.healthExpiresAt
        ))
    }
}
