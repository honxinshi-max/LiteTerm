import Foundation
import XCTest
@testable import LiteSpace

final class LoopbackPreviewServerTests: XCTestCase {
    func testServerBindsEphemeralLoopbackAndRequiresRunAuthentication() async throws {
        let server = LoopbackPreviewServer()
        let source = PreviewResponseSource.staticFiles([
            "index.html": PreviewResponse(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data("<h1>private preview</h1>".utf8)
            )
        ])
        let lease = try await server.start(
            generation: 7,
            runtimeID: UUID(),
            source: source
        )

        XCTAssertGreaterThan(lease.port, 0)
        XCTAssertEqual(lease.host, "127.0.0.1")
        XCTAssertEqual(lease.secretBitCount, 128)

        let unauthenticated = URL(string: "http://127.0.0.1:\(lease.port)/index.html")!
        let (_, unauthenticatedResponse) = try await URLSession.shared.data(from: unauthenticated)
        XCTAssertEqual((unauthenticatedResponse as? HTTPURLResponse)?.statusCode, 404)

        let authenticated = try lease.authenticatedBootstrapURL(relativePath: "index.html")
        let (data, response) = try await URLSession.shared.data(from: authenticated)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("<h1>private preview</h1>".utf8))
        XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly") == true)
        XCTAssertThrowsError(try lease.authenticatedBootstrapURL(relativePath: "../secret"))

        await server.stop()
        let isRunningAfterStop = await server.isRunning
        XCTAssertFalse(isRunningAfterStop)
    }

    func testHealthProbeRequiresThreeBoundedCurrentResponses() async throws {
        let server = LoopbackPreviewServer()
        let source = PreviewResponseSource.staticFiles([
            "health": PreviewResponse(status: 204, headers: [:], body: Data())
        ])
        let lease = try await server.start(
            generation: 11,
            runtimeID: UUID(),
            source: source
        )

        let result = try await HealthProbe().verify(lease: lease, relativePath: "health")
        XCTAssertEqual(result.consecutiveSuccesses, 3)
        XCTAssertEqual(result.generation, 11)

        await server.stop()
    }
}
