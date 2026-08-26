import XCTest
@testable import LiteSpaceCore

final class BoundedRuntimeOutputTests: XCTestCase {
    func testLineOverflowRetainsMarkerAndNewestCompleteLines() {
        var output = BoundedRuntimeOutput(lineLimit: 3, byteLimit: 100)
        output.append("one")
        output.append("two")
        output.append("three")
        output.append("four")

        XCTAssertEqual(output.lines, [BoundedRuntimeOutput.truncationMarker, "three", "four"])
        XCTAssertTrue(output.didTruncate)
        XCTAssertLessThanOrEqual(output.lines.count, 3)
    }

    func testByteOverflowBoundsNewestUTF8WithoutBreakingEncoding() {
        var output = BoundedRuntimeOutput(lineLimit: 10, byteLimit: 32)
        output.append(String(repeating: "修", count: 20))

        XCTAssertTrue(output.didTruncate)
        XCTAssertLessThanOrEqual(output.totalByteCount, 32)
        XCTAssertNotNil(output.lines.last?.data(using: .utf8))
    }

    func testClearReleasesRetainedOutputState() {
        var output = BoundedRuntimeOutput(lineLimit: 2, byteLimit: 40)
        output.append("one")
        output.append("two")
        output.append("three")
        output.clear()

        XCTAssertEqual(output.lines, [])
        XCTAssertEqual(output.totalByteCount, 0)
        XCTAssertFalse(output.didTruncate)
    }

    func testApprovedCandidateBudgetsStayExplicit() {
        let budget = RuntimeResourceBudget.iPadCandidate
        XCTAssertEqual(budget.idleResidentBytes, 90 * 1_024 * 1_024)
        XCTAssertEqual(budget.webResidentBytes, 160 * 1_024 * 1_024)
        XCTAssertEqual(budget.pythonResidentBytes, 180 * 1_024 * 1_024)
        XCTAssertEqual(budget.outputLineLimit, 2_000)
        XCTAssertEqual(budget.outputByteLimit, 2 * 1_024 * 1_024)
        XCTAssertEqual(budget.healthResponseByteLimit, 256 * 1_024)
        XCTAssertEqual(budget.maximumBackgroundRuntimeCount, 0)
    }
}
