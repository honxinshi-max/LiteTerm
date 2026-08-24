import XCTest
@testable import LiteTermCore

final class TerminalHistoryTests: XCTestCase {
    func testAppendDropsOldestLineBeyondLimit() {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.append("two")
        history.append("three")

        XCTAssertEqual(history.lines, ["two", "three"])
    }

    func testClearRemovesAllLines() {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.append("two")

        history.clear()

        XCTAssertEqual(history.lines, [])
    }

    func testZeroLimitKeepsNoLines() {
        var history = TerminalHistory(limit: 0)
        history.append("one")

        XCTAssertEqual(history.lines, [])
    }
}
