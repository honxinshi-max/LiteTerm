import XCTest
@testable import LiteTermCore

final class TerminalHistoryTests: XCTestCase {
    func testSingleHistoryEntryIsBounded() {
        var history = TerminalHistory(limit: 2)

        history.append(String(repeating: "a", count: 16_385))

        XCTAssertEqual(history.lines.first?.utf8.count, 16_384)
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

    func testOversizedLimitClampsToTwoHundredNewestLines() {
        var history = TerminalHistory(limit: 10_000)

        for index in 0...200 {
            history.append("\(index)")
        }

        XCTAssertEqual(history.lines.count, 200)
        XCTAssertEqual(history.lines.first, "1")
        XCTAssertEqual(history.lines.last, "200")
    }

    func testTotalByteBudgetDropsWholeOldestLines() {
        var history = TerminalHistory(limit: 10, totalByteLimit: 10)
        history.append("12345")
        history.append("67890")
        history.append("abc")

        XCTAssertEqual(history.lines, ["67890", "abc"])
        XCTAssertEqual(history.totalByteCount, 8)
    }

    func testPreviousAndNextNavigateWithoutGrowingHistory() {
        var history = TerminalHistory(limit: 10)
        history.append("pwd")
        history.append("ls")

        XCTAssertEqual(history.previous(), "ls")
        XCTAssertEqual(history.previous(), "pwd")
        XCTAssertEqual(history.previous(), "pwd")
        XCTAssertEqual(history.next(), "ls")
        XCTAssertEqual(history.next(), "")
        XCTAssertEqual(history.lines, ["pwd", "ls"])
    }
}
