import Foundation
import XCTest
@testable import LiteSpace

final class WorkspaceFileServiceTests: XCTestCase {
    func testInspectionAndSnapshotUseOnlyAcceptedRootContainedFiles() async throws {
        let root = try makeWorkspaceRoot()
        try Data("<h1>ready</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try Data("private".utf8).write(to: root.appendingPathComponent(".git/config"))

        let inspection = try await WorkspaceInventoryService().inspect(rootURL: root)
        XCTAssertEqual(inspection.classification.kind, .web)
        XCTAssertEqual(inspection.evaluation.acceptedFiles.map(\.relativePath), ["index.html"])

        let snapshot = try await WorkspaceSnapshotService().capture(
            generation: 3,
            rootURL: root,
            evaluation: inspection.evaluation
        )
        XCTAssertEqual(snapshot.entries.map(\.relativePath), ["index.html"])
        XCTAssertEqual(snapshot.entries.first?.sha256.count, 32)
        XCTAssertEqual(snapshot.manifestSHA256.count, 32)
    }

    func testProfileStoreKeysRootByOpaqueDigest() async throws {
        let suiteName = "LiteSpace.WorkspaceProfileStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkspaceProfileStore(defaults: defaults, namespace: suiteName)
        let profile = try WorkspaceProfile(
            kind: .web,
            entrypoint: "index.html",
            testConvention: .webSmoke(relativePaths: []),
            healthPath: ""
        )

        try await store.save(profile, rootIdentity: Data("opaque-root".utf8))
        let loadedProfile = try await store.load(rootIdentity: Data("opaque-root".utf8))
        XCTAssertEqual(loadedProfile, profile)
        let keys = try XCTUnwrap(UserDefaults(suiteName: suiteName)).dictionaryRepresentation().keys
        XCTAssertFalse(keys.contains(where: { $0.contains("opaque-root") || $0.contains("/Users/") }))
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteSpace-Workspace-Service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
