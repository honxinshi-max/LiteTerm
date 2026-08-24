import Darwin
import LiteTermCore

@main
struct LiteTermCoreTestRunner {
    static func main() {
        var failures: [String] = []

        checkHistoryDropsOldestLine(&failures)
        checkHistoryClear(&failures)
        checkZeroHistoryLimit(&failures)
        checkOversizedHistoryLimit(&failures)
        checkControlLettersAndBracket(&failures)
        checkControlUppercasing(&failures)
        checkUnsupportedControlCharacters(&failures)

        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }

        print("PASS: 7 LiteTermCore terminal primitive checks")
    }

    private static func checkHistoryDropsOldestLine(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.append("two")
        history.append("three")
        expect(history.lines == ["two", "three"], "history retains the newest lines", &failures)
    }

    private static func checkHistoryClear(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.clear()
        expect(history.lines == [], "history clear removes all lines", &failures)
    }

    private static func checkZeroHistoryLimit(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 0)
        history.append("one")
        expect(history.lines == [], "zero history limit retains no lines", &failures)
    }

    private static func checkOversizedHistoryLimit(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 10_000)

        for index in 0...2_000 {
            history.append("\(index)")
        }

        expect(history.lines.count == 2_000, "oversized history limit is capped at 2,000 lines", &failures)
        expect(history.lines.first == "1", "oversized history drops its oldest line", &failures)
        expect(history.lines.last == "2000", "oversized history retains its newest line", &failures)
    }

    private static func checkControlLettersAndBracket(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("c") == 0x03, "Ctrl-C encodes as 0x03", &failures)
        expect(ControlKeyEncoder.encode("[") == 0x1B, "Ctrl-[ encodes as 0x1B", &failures)
    }

    private static func checkControlUppercasing(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("z") == 0x1A, "lowercase Ctrl-Z encodes as 0x1A", &failures)
        expect(ControlKeyEncoder.encode("Z") == 0x1A, "uppercase Ctrl-Z encodes as 0x1A", &failures)
    }

    private static func checkUnsupportedControlCharacters(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("`") == nil, "backtick is not a control combination", &failures)
        expect(ControlKeyEncoder.encode("é") == nil, "non-ASCII input is not a control combination", &failures)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        _ failures: inout [String]
    ) {
        if !condition() {
            failures.append(message)
        }
    }
}
