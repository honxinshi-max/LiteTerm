import Foundation
import XCTest
@testable import LiteSpaceCore

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
                savedFingerprint: " SHA256: \(fingerprint)= ",
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

    func testEqualArbitraryStringsAreRejected() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "not-a-fingerprint",
                presentedFingerprint: "not-a-fingerprint"
            ),
            .mismatch
        )
    }

    func testMalformedPresentedFingerprintCannotReachFirstUseTrust() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: nil,
                presentedFingerprint: "SHA256:not-base64"
            ),
            .mismatch
        )
    }

    func testWrongDigestLengthIsRejectedEvenWhenValuesMatch() {
        let shortDigest = Data(repeating: 0, count: 31).base64EncodedString()

        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "SHA256:\(shortDigest)",
                presentedFingerprint: "SHA256:\(shortDigest)"
            ),
            .mismatch
        )
    }

    func testNonCanonicalPaddingIsRejected() {
        XCTAssertEqual(
            KnownHostPolicy.evaluate(
                savedFingerprint: "SHA256:\(fingerprint)==",
                presentedFingerprint: "SHA256:\(fingerprint)=="
            ),
            .mismatch
        )
    }
}
