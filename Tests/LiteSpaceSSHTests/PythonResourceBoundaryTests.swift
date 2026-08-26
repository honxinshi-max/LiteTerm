import Foundation
import XCTest
@testable import LiteSpace

final class PythonResourceBoundaryTests: XCTestCase {
    func testWSGIRejectsOversizedRequestAndResponse() {
        XCTAssertThrowsError(try PythonWSGIAdapter.makeRequest(from: PreviewRequest(
            method: "POST",
            relativePath: "api",
            query: nil,
            headers: [:],
            body: Data(repeating: 0x41, count: PythonWSGIAdapter.maximumRequestBytes + 1)
        )))
        XCTAssertThrowsError(try PythonWSGIAdapter.makePreviewResponse(from: PythonWSGIResponseEnvelope(
            status: "200 OK",
            headers: [],
            body: Data(repeating: 0x41, count: PythonWSGIAdapter.maximumResponseBytes + 1)
        )))
    }

    func testWSGIRejectsHeaderInjectionAndUnsupportedMethods() {
        XCTAssertThrowsError(try PythonWSGIAdapter.makeRequest(from: PreviewRequest(
            method: "CONNECT",
            relativePath: "",
            query: nil,
            headers: [:],
            body: Data()
        )))
        XCTAssertThrowsError(try PythonWSGIAdapter.makePreviewResponse(from: PythonWSGIResponseEnvelope(
            status: "200 OK",
            headers: [PythonWSGIHeader(name: "X-Test", value: "ok\r\nInjected: value")],
            body: Data()
        )))
    }
}
