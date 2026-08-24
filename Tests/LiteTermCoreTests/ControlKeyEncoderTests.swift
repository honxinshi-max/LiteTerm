import XCTest
@testable import LiteTermCore

final class ControlKeyEncoderTests: XCTestCase {
    func testControlLettersAndBracketProduceTerminalBytes() {
        XCTAssertEqual(ControlKeyEncoder.encode("c"), 0x03)
        XCTAssertEqual(ControlKeyEncoder.encode("["), 0x1B)
    }

    func testControlEncodingUppercasesLetters() {
        XCTAssertEqual(ControlKeyEncoder.encode("z"), 0x1A)
        XCTAssertEqual(ControlKeyEncoder.encode("Z"), 0x1A)
    }

    func testControlEncodingRejectsUnsupportedCharacters() {
        XCTAssertNil(ControlKeyEncoder.encode("`"))
        XCTAssertNil(ControlKeyEncoder.encode("é"))
    }
}
