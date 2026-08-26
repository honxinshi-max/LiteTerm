import Foundation
import XCTest
@testable import LiteSpace

final class PythonWorkspaceRunnerTests: XCTestCase {
    func testMissingVerifiedArtifactFailsClosedWithoutCompilationClaim() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteSpace-PythonRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("print('private')".utf8).write(to: root.appendingPathComponent("main.py"))
        let inspection = try await WorkspaceInventoryService().inspect(rootURL: root)
        let snapshot = try await WorkspaceSnapshotService().captureBundle(
            generation: 1,
            rootURL: root,
            evaluation: inspection.evaluation
        )
        let profile = try WorkspaceProfile(
            kind: .python,
            entrypoint: "main.py",
            testConvention: .none,
            healthPath: ""
        )

        let report = await PythonWorkspaceRunner().check(snapshot: snapshot, profile: profile)

        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.didCompile)
        XCTAssertTrue(report.problems.contains { $0.category == .unsupported })
    }
}
