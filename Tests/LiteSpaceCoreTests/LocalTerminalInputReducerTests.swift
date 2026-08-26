import XCTest
@testable import LiteSpaceCore

final class LocalTerminalInputReducerTests: XCTestCase {
    func testOversizedPasteIsBoundedAndBackspaceReleasesCapacity() {
        var reducer = LocalTerminalInputReducer(maximumInputBytes: 8)
        let oversized = Array(repeating: UInt8(ascii: "a"), count: 9)

        let pasteEvents = reducer.reduce(oversized)
        let echoedByteCount = pasteEvents.reduce(into: 0) { count, event in
            if case .echo(let bytes) = event {
                count += bytes.count
            }
        }
        XCTAssertEqual(echoedByteCount, 8)

        _ = reducer.reduce([0x7F])
        _ = reducer.reduce([UInt8(ascii: "b")])
        let submitEvents = reducer.reduce([0x0D])
        guard case .submit(let command) = submitEvents.last else {
            return XCTFail("bounded Local input must remain submittable")
        }
        XCTAssertEqual(command.utf8.count, 8)
        XCTAssertEqual(command.last, "b")
    }

    func testSplitEmojiIsEchoedAndSubmittedAsOneCompleteScalar() {
        var reducer = LocalTerminalInputReducer(maximumInputBytes: 8)
        let emoji = Array("😀".utf8)

        XCTAssertEqual(reducer.reduce(Array(emoji.prefix(2))), [])
        XCTAssertEqual(reducer.bufferedPartialScalarByteCount, 2)
        XCTAssertEqual(reducer.reduce(Array(emoji.suffix(2))), [.echo(emoji)])
        XCTAssertEqual(reducer.bufferedPartialScalarByteCount, 0)
        XCTAssertEqual(reducer.reduce([0x0D]), [.submit("😀")])
    }

    func testCompleteScalarThatCrossesExactBoundaryIsRejectedAtomically() {
        var reducer = LocalTerminalInputReducer(maximumInputBytes: 5)
        XCTAssertEqual(reducer.reduce(Array("abc".utf8)), [.echo(Array("abc".utf8))])

        XCTAssertEqual(reducer.reduce(Array("😀".utf8)), [])
        XCTAssertEqual(reducer.reduce([0x0D]), [.submit("abc")])
    }

    func testMultilinePasteHasOneBoundedEventBudget() {
        var reducer = LocalTerminalInputReducer(maximumEventsPerReduction: 6)
        let events = reducer.reduce(Array(String(repeating: "x\n", count: 100).utf8))

        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events, [
            .echo([UInt8(ascii: "x")]), .submit("x"),
            .echo([UInt8(ascii: "x")]), .submit("x"),
            .echo([UInt8(ascii: "x")]), .submit("x")
        ])
    }

    func testHistoryUpAndDownReplacesCurrentLocalInput() {
        var reducer = LocalTerminalInputReducer()
        _ = reducer.reduce(Array("pwd\r".utf8))
        _ = reducer.reduce(Array("ls\r".utf8))

        XCTAssertEqual(reducer.navigateHistory(.previous), [.replaceLine(Array("ls".utf8))])
        XCTAssertEqual(reducer.navigateHistory(.previous), [.replaceLine(Array("pwd".utf8))])
        XCTAssertEqual(reducer.navigateHistory(.next), [.replaceLine(Array("ls".utf8))])
        XCTAssertEqual(reducer.navigateHistory(.next), [.replaceLine([])])
    }

    func testCommandEchoPrecedesSubmit() {
        var reducer = LocalTerminalInputReducer()

        XCTAssertEqual(
            reducer.reduce(Array("pwd\r".utf8)),
            [
                .echo(Array("pwd".utf8)),
                .submit("pwd")
            ]
        )
    }

    func testMultilinePastePreservesEchoAndSubmitOrder() {
        var reducer = LocalTerminalInputReducer()

        XCTAssertEqual(
            reducer.reduce(Array("pwd\r\nls\r".utf8)),
            [
                .echo(Array("pwd".utf8)),
                .submit("pwd"),
                .echo(Array("ls".utf8)),
                .submit("ls")
            ]
        )
    }

    func testPrintableRunsFlushBeforeEditingAndInterruptControls() {
        var reducer = LocalTerminalInputReducer()

        XCTAssertEqual(
            reducer.reduce(Array("ab".utf8) + [0x7F] + Array("c".utf8) + [0x03]),
            [
                .echo(Array("ab".utf8)),
                .erase,
                .echo(Array("c".utf8)),
                .interrupt
            ]
        )
    }

    func testEchoAndInterruptReserveTheExactEventBudgetAtomically() {
        var exact = LocalTerminalInputReducer(maximumEventsPerReduction: 2)
        XCTAssertEqual(
            exact.reduce([UInt8(ascii: "a"), 0x03]),
            [.echo([UInt8(ascii: "a")]), .interrupt]
        )

        var insufficient = LocalTerminalInputReducer(maximumEventsPerReduction: 1)
        let first = insufficient.reduce([UInt8(ascii: "a"), 0x03])
        XCTAssertEqual(first, [.echo([UInt8(ascii: "a")])])
        XCTAssertEqual(first.count <= 1, true)
        XCTAssertEqual(insufficient.reduce([0x03]), [.interrupt])
    }

    func testEchoAndEraseNeverExceedAnInsufficientEventBudget() {
        var reducer = LocalTerminalInputReducer(maximumEventsPerReduction: 1)

        let first = reducer.reduce([UInt8(ascii: "a"), 0x7F])

        XCTAssertEqual(first, [.echo([UInt8(ascii: "a")])])
        XCTAssertEqual(first.count <= 1, true)
        XCTAssertEqual(reducer.reduce([0x7F]), [.erase])
    }
}
