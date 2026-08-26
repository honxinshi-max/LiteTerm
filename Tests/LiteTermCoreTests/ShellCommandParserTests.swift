import XCTest
@testable import LiteTermCore

final class ShellCommandParserTests: XCTestCase {
    private let parser = ShellCommandParser()

    func testParserPreservesQuotedFileName() throws {
        let command = try parser.parse("touch \"two words.txt\"")
        XCTAssertEqual(command, .touch(path: "two words.txt"))
    }

    func testParserIgnoresOuterWhitespace() throws {
        let command = try parser.parse("  mkdir   notes  ")
        XCTAssertEqual(command, .mkdir(path: "notes"))
    }

    func testParserRecognizesEverySupportedCommand() throws {
        let pwd = try parser.parse("pwd")
        XCTAssertEqual(pwd, .pwd)
        let commands: [(String, ShellCommand)] = [
            ("ls", .ls(path: nil)),
            ("ls docs", .ls(path: "docs")),
            ("cd docs", .cd(path: "docs")),
            ("cat readme.txt", .cat(path: "readme.txt")),
            ("mkdir docs", .mkdir(path: "docs")),
            ("touch draft.txt", .touch(path: "draft.txt")),
            ("cp one.txt two.txt", .copy(source: "one.txt", destination: "two.txt")),
            ("mv one.txt two.txt", .move(source: "one.txt", destination: "two.txt")),
            ("rm old.txt", .remove(path: "old.txt")),
            ("clear", .clear),
            ("edit draft.txt", .edit(path: "draft.txt")),
            ("workspace", .workspace(action: .showStatus)),
            ("check", .workspace(action: .check)),
            ("test", .workspace(action: .test)),
            ("run", .workspace(action: .run)),
            ("stop", .workspace(action: .stop)),
            ("problems", .workspace(action: .showProblems)),
            ("ports", .workspace(action: .showPorts))
        ]

        for (input, expected) in commands {
            let command = try parser.parse(input)
            XCTAssertEqual(command, expected)
        }
    }

    func testParserRejectsUnknownCommand() {
        XCTAssertParserError("launch", equals: .unknownCommand("launch"))
    }

    func testParserRejectsWrongArity() {
        XCTAssertParserError("cp one.txt", equals: .wrongArity(command: "cp"))
        XCTAssertParserError("pwd unexpected", equals: .wrongArity(command: "pwd"))
        XCTAssertParserError("run main.py", equals: .wrongArity(command: "run"))
    }

    func testParserRejectsUnterminatedQuote() {
        XCTAssertParserError("touch \"unfinished", equals: .unterminatedQuote)
    }

    private func XCTAssertParserError(
        _ input: String,
        equals expected: ShellCommandParserError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try parser.parse(input)
            XCTFail("Expected parser error", file: file, line: line)
        } catch let error as ShellCommandParserError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
