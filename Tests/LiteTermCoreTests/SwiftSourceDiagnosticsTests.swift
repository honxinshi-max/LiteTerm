import XCTest
@testable import LiteTermCore

final class SwiftSourceDiagnosticsTests: XCTestCase {
    func testRejectsInvalidUTF8() {
        let problems = SwiftSourceDiagnostics.inspect(
            data: Data([0xFF]),
            relativePath: "Sources/App.swift"
        )

        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.category, .syntax)
    }

    func testReportsConflictMarkersAndUnmatchedDelimiters() {
        let source = """
        func run() {
        <<<<<<< HEAD
          print("ok")
        =======
          print("other")
        >>>>>>> branch
        """

        let problems = SwiftSourceDiagnostics.inspect(
            data: Data(source.utf8),
            relativePath: "main.swift"
        )

        XCTAssertTrue(problems.contains { $0.message == "Unresolved source-control conflict marker." })
        XCTAssertTrue(problems.contains { $0.message == "Unclosed '{' delimiter." })
    }

    func testIgnoresDelimitersInsideCommentsAndStrings() {
        let source = #"""
        // } ] )
        let text = "{"
        /* nested /* } */ comment */
        func run() { print(text) }
        """#

        XCTAssertEqual(
            SwiftSourceDiagnostics.inspect(
                data: Data(source.utf8),
                relativePath: "main.swift"
            ),
            []
        )
    }

    func testReportsUnterminatedStringAndComment() {
        let stringProblems = SwiftSourceDiagnostics.inspect(
            data: Data("let text = \"unfinished".utf8),
            relativePath: "main.swift"
        )
        XCTAssertTrue(stringProblems.contains { $0.message == "Unterminated string literal." })

        let commentProblems = SwiftSourceDiagnostics.inspect(
            data: Data("/* unfinished".utf8),
            relativePath: "main.swift"
        )
        XCTAssertTrue(commentProblems.contains { $0.message == "Unterminated block comment." })
    }
}
