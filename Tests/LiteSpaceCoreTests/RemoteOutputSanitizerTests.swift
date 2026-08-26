import XCTest
@testable import LiteSpaceCore

final class RemoteOutputSanitizerTests: XCTestCase {
    func testOrdinaryBytesAndNonDCSescapesPassThrough() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize(Array("hello".utf8) + [0x1B, 0x5B, 0x41]),
            Array("hello".utf8) + [0x1B, 0x5B, 0x41]
        )
    }

    func testOrdinaryRepeatedEscapesPassThrough() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize([0x1B, 0x1B, 0x5B, 0x41]),
            [0x1B, 0x1B, 0x5B, 0x41]
        )
    }

    func testCompleteSevenBitAndEightBitDCSAreStripped() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize([0x61, 0x1B, 0x50] + Array("qpayload".utf8) + [0x1B, 0x5C, 0x62]),
            [0x61, 0x62]
        )
        XCTAssertEqual(
            sanitizer.sanitize([0x63, 0x90] + Array("payload".utf8) + [0x9C, 0x64]),
            [0x63, 0x64]
        )
    }

    func testSplitIntroducerAndTerminatorAreStrippedAcrossChunks() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x61, 0x1B]), [0x61])
        XCTAssertEqual(sanitizer.bufferedByteCount, 1)
        XCTAssertEqual(sanitizer.sanitize([0x50, 0x71, 0x31, 0x1B]), [])
        XCTAssertEqual(sanitizer.bufferedByteCount, 1)
        XCTAssertEqual(sanitizer.sanitize([0x5C, 0x62]), [0x62])
    }

    func testCANcancelsSevenBitDCSAcrossChunks() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x61, 0x1B, 0x50, 0x71, 0x31]), [0x61])
        XCTAssertEqual(sanitizer.sanitize([0x18, 0x62]), [0x62])
    }

    func testSUBcancelsEightBitDCSAcrossChunks() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x61, 0x90, 0x71, 0x31]), [0x61])
        XCTAssertEqual(sanitizer.sanitize([0x1A, 0x62]), [0x62])
    }

    func testNonSTAfterSplitEscapeExitsDCSAndPreservesEscapeSequence() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B]), [])
        XCTAssertEqual(sanitizer.bufferedByteCount, 1)
        XCTAssertEqual(
            sanitizer.sanitize([0x5B, 0x33, 0x31, 0x6D, 0x4F, 0x4B]),
            [0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x4F, 0x4B]
        )
    }

    func testRepeatedEscapeStartsANewEscapeSequenceAcrossChunks() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B]), [])
        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x1B]), [])
        XCTAssertEqual(sanitizer.bufferedByteCount, 1)
        XCTAssertEqual(sanitizer.sanitize([0x5B, 0x41]), [0x1B, 0x5B, 0x41])
    }

    func testEscapePReentersDCSWithoutLeakingPayload() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B]), [])
        XCTAssertEqual(
            sanitizer.sanitize([0x50, 0x71, 0x32, 0x33, 0x1B, 0x5C, 0x62]),
            [0x62]
        )
    }

    func testEscapeThenC1DCSReentersWithoutLeavingTerminalEscapeState() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize([0x1B, 0x90, 0x71, 0x32, 0x33, 0x9C, 0x62]),
            [0x62]
        )
    }

    func testDCSBodyIsNeverRetained() {
        var sanitizer = RemoteOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x50]), [])
        for _ in 0..<128 {
            XCTAssertEqual(sanitizer.sanitize(Array(repeating: 0x71, count: 8_192)), [])
            XCTAssertEqual(sanitizer.bufferedByteCount, 0)
        }
        XCTAssertEqual(sanitizer.sanitize([0x1B, 0x5C, 0x7A]), [0x7A])
    }
}
