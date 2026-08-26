import XCTest
@testable import LiteSpaceCore

final class ShortcutInputReducerTests: XCTestCase {
    func testControlLatchesForOnePrintableASCIICharacter() {
        var reducer = ShortcutInputReducer()

        XCTAssertEqual(reducer.handleShortcut(.control), [])
        XCTAssertEqual(reducer.isControlLatched, true)
        XCTAssertEqual(reducer.reduceText("c"), [0x03])
        XCTAssertEqual(reducer.isControlLatched, false)
        XCTAssertEqual(reducer.reduceText("c"), [0x63])
    }

    func testTerminalShortcutsEmitLiteralAndANSIBytes() {
        var reducer = ShortcutInputReducer()

        XCTAssertEqual(reducer.handleShortcut(.escape), [0x1B])
        XCTAssertEqual(reducer.handleShortcut(.tab), [0x09])
        XCTAssertEqual(reducer.handleShortcut(.up), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(reducer.handleShortcut(.down), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(reducer.handleShortcut(.right), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(reducer.handleShortcut(.left), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(reducer.handleShortcut(.slash), [0x2F])
    }

    func testUnsupportedPrintableControlInputPassesThroughAndClearsLatch() {
        var reducer = ShortcutInputReducer()
        _ = reducer.handleShortcut(.control)

        XCTAssertEqual(reducer.reduceText("1"), [0x31])
        XCTAssertEqual(reducer.isControlLatched, false)
    }
}
