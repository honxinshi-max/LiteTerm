import XCTest
@testable import LiteTermCore

final class LocalTerminalInputReducerTests: XCTestCase {
    func testOversizedPasteIsBoundedAndBackspaceReleasesCapacity() {
        var reducer = LocalTerminalInputReducer()
        let oversized = Array(repeating: UInt8(ascii: "a"), count: 65_537)

        let pasteEvents = reducer.reduce(oversized)
        let echoedByteCount = pasteEvents.reduce(into: 0) { count, event in
            if case .echo(let bytes) = event {
                count += bytes.count
            }
        }
        XCTAssertEqual(echoedByteCount, 65_536)

        _ = reducer.reduce([0x7F])
        _ = reducer.reduce([UInt8(ascii: "b")])
        let submitEvents = reducer.reduce([0x0D])
        guard case .submit(let command) = submitEvents.last else {
            return XCTFail("bounded Local input must remain submittable")
        }
        XCTAssertEqual(command.utf8.count, 65_536)
        XCTAssertEqual(command.last, "b")
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
}
