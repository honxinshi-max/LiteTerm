import XCTest
@testable import LiteTermCore

final class LocalTerminalInputReducerTests: XCTestCase {
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
