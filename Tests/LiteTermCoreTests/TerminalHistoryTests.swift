import XCTest
@testable import LiteTermCore

final class TerminalHistoryTests: XCTestCase {
    func testSingleHistoryEntryIsBounded() {
        var history = TerminalHistory(limit: 2)

        history.append(String(repeating: "a", count: 65_537))

        XCTAssertEqual(history.lines.first?.utf8.count, 65_536)
    }

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

    func testOversizedLimitClampsToTwoThousandNewestLines() {
        var history = TerminalHistory(limit: 10_000)

        for index in 0...2_000 {
            history.append("\(index)")
        }

        XCTAssertEqual(history.lines.count, 2_000)
        XCTAssertEqual(history.lines.first, "1")
        XCTAssertEqual(history.lines.last, "2000")
    }
}
