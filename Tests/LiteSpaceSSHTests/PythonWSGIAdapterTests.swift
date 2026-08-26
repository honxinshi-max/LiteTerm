import Foundation
import XCTest
@testable import LiteSpace

final class PythonWSGIAdapterTests: XCTestCase {
    func testRequestEnvelopeContainsNoSecretAbsolutePathOrUserAgent() throws {
        let request = PreviewRequest(
            method: "POST",
            relativePath: "api/item",
            query: "page=1",
            headers: [
                "Content-Type": "application/json",
                "User-Agent": "private-device-detail",
                "X-LiteSpace-Run": "private-secret"
            ],
            body: Data("{}".utf8)
        )

        let envelope = try PythonWSGIAdapter.makeRequest(from: request)

        XCTAssertEqual(envelope.pathInfo, "/api/item")
        XCTAssertEqual(envelope.environ["SERVER_NAME"], "localhost")
        XCTAssertNil(envelope.environ["HTTP_USER_AGENT"])
        XCTAssertFalse(envelope.environ.values.contains { $0.contains("private-secret") })
    }

    func testResponseValidationRemovesHopByHopHeadersAndBoundsBody() throws {
        let response = try PythonWSGIAdapter.makePreviewResponse(from: PythonWSGIResponseEnvelope(
            status: "200 OK",
            headers: [
                PythonWSGIHeader(name: "Content-Type", value: "text/plain"),
                PythonWSGIHeader(name: "Connection", value: "keep-alive")
            ],
            body: Data("ok".utf8)
        ))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        XCTAssertNil(response.headers["Connection"])

        XCTAssertThrowsError(try PythonWSGIAdapter.makePreviewResponse(from: PythonWSGIResponseEnvelope(
            status: "200 OK",
            headers: [],
            body: Data(repeating: 0x41, count: 5 * 1_024 * 1_024 + 1)
        )))
    }
}
