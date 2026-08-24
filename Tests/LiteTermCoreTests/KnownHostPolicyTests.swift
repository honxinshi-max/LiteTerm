import XCTest
@testable import LiteTermCore

final class KnownHostPolicyTests: XCTestCase {
    private let fingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testMissingSavedFingerprintRequiresExplicitTrust() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: nil,
                presentedFingerprint: "SHA256:\(fingerprint)"
            ),
            .needsTrust
        )
    }

    func testExactNormalizedFingerprintIsTrusted() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "SHA256:\(fingerprint)",
                presentedFingerprint: "SHA256:\(fingerprint)"
            ),
            .trusted
        )
    }

    func testChangedFingerprintHardFails() {
        let changed = "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "SHA256:\(fingerprint)",
                presentedFingerprint: "SHA256:\(changed)"
            ),
            .mismatch
        )
    }

    func testPrefixCaseAndOptionalBase64PaddingAreNormalized() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: " SHA256:\(fingerprint)= ",
                presentedFingerprint: "sha256:\(fingerprint)"
            ),
            .trusted
        )
    }

    func testFingerprintPayloadComparisonRemainsCaseSensitive() {
        let changedCase = "a" + fingerprint.dropFirst()

        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "SHA256:\(fingerprint)",
                presentedFingerprint: "SHA256:\(changedCase)"
            ),
            .mismatch
        )
    }
}
