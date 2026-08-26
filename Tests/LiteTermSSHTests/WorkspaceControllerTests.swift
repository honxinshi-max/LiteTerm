import Foundation
import XCTest
@testable import LiteTerm

@MainActor
final class WorkspaceControllerTests: XCTestCase {
    func testWebRunPublishesOnlyReadyPortAndEditWithdrawsIt() async throws {
        let root = try makeRoot(files: [
            "index.html": "<h1>Ready</h1>"
        ])
        let controller = WorkspaceController(rootURL: root)

        controller.perform(.run)
        try await waitUntil { controller.presentation.publishedPort != nil }

        XCTAssertEqual(controller.presentation.state, .ready)
        XCTAssertNotNil(controller.presentation.publishedPort)

        await controller.sourceDidChange()
        XCTAssertNil(controller.presentation.publishedPort)
        XCTAssertEqual(controller.presentation.state, .idle)
    }

    func testExternalSourceMutationWithdrawsReadyPort() async throws {
        let root = try makeRoot(files: [
            "index.html": "<h1>Ready</h1>"
        ])
        let controller = WorkspaceController(rootURL: root)

        controller.perform(.run)
        try await waitUntil { controller.presentation.publishedPort != nil }

        try Data("<h1>Externally changed</h1>".utf8).write(
            to: root.appendingPathComponent("index.html"),
            options: .atomic
        )
        try await waitUntil {
            controller.presentation.publishedPort == nil
                && controller.presentation.state == .failed
        }

        XCTAssertTrue(controller.presentation.problems.contains { $0.category == .fileAccess })
    }

    func testSwiftNeverPublishesPortAndOffersHandoff() async throws {
        let root = try makeRoot(files: [
            "main.swift": "func run() {}"
        ])
        let controller = WorkspaceController(rootURL: root)

        controller.perform(.run)
        try await waitUntil { controller.presentation.state == .checked }

        XCTAssertNil(controller.presentation.publishedPort)
        XCTAssertEqual(controller.presentation.runtimeLabel, "Lightweight diagnostics")
        XCTAssertNotNil(controller.presentation.playgroundsHandoff)
    }

    func testUnsupportedWorkspaceFailsClosed() async throws {
        let root = try makeRoot(files: ["notes.txt": "text"])
        let controller = WorkspaceController(rootURL: root)

        controller.perform(.run)
        try await waitUntil { controller.presentation.state == .failed }

        XCTAssertNil(controller.presentation.publishedPort)
        XCTAssertTrue(controller.presentation.problems.contains { $0.category == .unsupported })
    }

    func testPythonRecognitionDoesNotPublishPortWithoutVerifiedArtifact() async throws {
        let root = try makeRoot(files: ["main.py": "print('private')"])
        let controller = WorkspaceController(rootURL: root)

        controller.perform(.run)
        try await waitUntil { controller.presentation.state == .failed }

        XCTAssertEqual(controller.presentation.kind, .python)
        XCTAssertEqual(controller.presentation.runtimeLabel, "Embedded Python")
        XCTAssertNil(controller.presentation.publishedPort)
        XCTAssertTrue(controller.presentation.problems.contains { $0.category == .unsupported })
    }

    private func makeRoot(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-WorkspaceControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, source) in files {
            try Data(source.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw PreviewRuntimeError.healthTimedOut }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
