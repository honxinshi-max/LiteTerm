import Foundation
import XCTest
@testable import LiteSpaceCore

final class WorkspaceProblemTests: XCTestCase {
    func testProblemKeepsBoundedLocalDetailButPersistenceProjectionDropsIt() throws {
        let problem = try WorkspaceProblem(
            stage: .check,
            severity: .error,
            category: .syntax,
            relativePath: "Sources/private-name.swift",
            line: 12,
            column: 4,
            message: String(repeating: "é", count: 400),
            recoveryAction: String(repeating: "修", count: 200)
        )

        XCTAssertLessThanOrEqual(problem.message.utf8.count, 512)
        XCTAssertLessThanOrEqual(problem.recoveryAction?.utf8.count ?? 0, 256)

        let encoded = try JSONEncoder().encode(problem.persistenceProjection)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-name"))
        XCTAssertFalse(text.contains("Sources"))
        XCTAssertFalse(text.contains("é"))
        XCTAssertEqual(problem.persistenceProjection.category, .syntax)
    }

    func testProblemRejectsAbsoluteOrEscapingLocator() {
        XCTAssertThrowsError(try WorkspaceProblem(
            stage: .inspect,
            severity: .error,
            category: .privacy,
            relativePath: "/private/file.py",
            message: "denied"
        ))
        XCTAssertThrowsError(try WorkspaceProblem(
            stage: .inspect,
            severity: .error,
            category: .privacy,
            relativePath: "../file.py",
            message: "denied"
        ))
    }
}
