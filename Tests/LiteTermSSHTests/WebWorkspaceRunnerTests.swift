import Foundation
import XCTest
@testable import LiteTerm

final class WebWorkspaceRunnerTests: XCTestCase {
    func testStaticValidationAcceptsOnlyCompleteLocalWebSource() async throws {
        let valid = try await capture([
            "index.html": "<link rel=\"stylesheet\" href=\"style.css\"><script src=\"app.js\"></script>",
            "style.css": "body { color: black; }",
            "app.js": "globalThis.ready = true;"
        ])
        let profile = try WorkspaceProfile(
            kind: .web,
            entrypoint: "index.html",
            testConvention: .webSmoke(relativePaths: []),
            healthPath: ""
        )

        XCTAssertTrue(WebWorkspaceRunner.validate(snapshot: valid, profile: profile).problems.isEmpty)

        let missing = try await capture([
            "index.html": "<script src=\"missing.js\"></script>"
        ])
        XCTAssertTrue(
            WebWorkspaceRunner.validate(snapshot: missing, profile: profile).problems.contains {
                $0.category == .configuration
            }
        )

        let external = try await capture([
            "index.html": "<script src=\"https://example.invalid/app.js\"></script>"
        ])
        XCTAssertTrue(
            WebWorkspaceRunner.validate(snapshot: external, profile: profile).problems.contains {
                $0.category == .privacy
            }
        )
    }

    func testClassicJavaScriptSyntaxFailureBlocksValidation() async throws {
        let snapshot = try await capture([
            "index.html": "<script src=\"app.js\"></script>",
            "app.js": "function broken( {"
        ])
        let profile = try WorkspaceProfile(
            kind: .web,
            entrypoint: "index.html",
            testConvention: .none,
            healthPath: ""
        )

        XCTAssertTrue(
            WebWorkspaceRunner.validate(snapshot: snapshot, profile: profile).problems.contains {
                $0.category == .syntax
            }
        )
    }

    func testSwiftAdvisorIsCheckOnlyAndOffersExplicitPlaygroundsHandoff() async throws {
        let snapshot = try await capture([
            "main.swift": "func run() {"
        ])

        let advice = SwiftWorkspaceAdvisor().inspect(snapshot: snapshot)

        XCTAssertEqual(advice.label, "Lightweight diagnostics")
        XCTAssertFalse(advice.canRunLocally)
        XCTAssertEqual(advice.handoff.kind, .shareToSwiftPlaygrounds)
        XCTAssertTrue(advice.problems.contains { $0.category == .syntax })
    }

    @MainActor
    func testSmokeCapturesRuntimeFailuresAndDeniesCapabilities() async throws {
        let server = LoopbackPreviewServer()
        let html = """
        <script>
          Promise.reject(new Error('private detail'));
          window.open('/index.html');
          const link = document.createElement('a');
          link.href = '/asset.txt';
          link.download = 'private.txt';
          link.click();
        </script>
        <img src="missing.png">
        """
        let source = PreviewResponseSource.staticFiles([
            "index.html": PreviewResponse(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            ),
            "asset.txt": PreviewResponse(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("private".utf8)
            )
        ])
        let lease = try await server.start(generation: 8, runtimeID: UUID(), source: source)

        let problems = await WebWorkspaceRunner().smoke(
            lease: lease,
            entrypoint: "index.html",
            timeout: .seconds(5)
        )

        XCTAssertTrue(problems.contains { $0.category == .runtime })
        XCTAssertTrue(problems.contains { $0.category == .fileAccess })
        XCTAssertTrue(problems.contains { $0.category == .privacy })
        XCTAssertTrue(problems.contains { $0.message == "A Web download was blocked." })
        await server.stop()
    }

    private func capture(_ files: [String: String]) async throws -> WorkspaceCapturedSnapshot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-WebRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, source) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(source.utf8).write(to: fileURL)
        }
        let inspection = try await WorkspaceInventoryService().inspect(rootURL: root)
        return try await WorkspaceSnapshotService().captureBundle(
            generation: 1,
            rootURL: root,
            evaluation: inspection.evaluation
        )
    }
}
