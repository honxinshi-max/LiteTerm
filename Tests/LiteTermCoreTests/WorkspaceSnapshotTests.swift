import Foundation
import XCTest
@testable import LiteTermCore

final class WorkspaceSnapshotTests: XCTestCase {
    func testProfileAcceptsOnlyNormalizedRelativeRuntimeConfiguration() throws {
        let profile = try WorkspaceProfile(
            kind: .web,
            entrypoint: "public/index.html",
            testConvention: .webSmoke(relativePaths: ["tests/smoke.js"]),
            healthPath: "health"
        )

        XCTAssertEqual(profile.entrypoint, "public/index.html")
        XCTAssertEqual(profile.healthPath, "health")
    }

    func testProfileRejectsAbsoluteTraversalAuthorityAndQueryPaths() {
        XCTAssertThrowsError(try WorkspaceProfile(
            kind: .web,
            entrypoint: "/private/index.html",
            testConvention: .none,
            healthPath: ""
        ))
        XCTAssertThrowsError(try WorkspaceProfile(
            kind: .python,
            entrypoint: "../main.py",
            testConvention: .none,
            healthPath: ""
        ))
        XCTAssertThrowsError(try WorkspaceProfile(
            kind: .web,
            entrypoint: "index.html",
            testConvention: .none,
            healthPath: "https://example.invalid/health"
        ))
        XCTAssertThrowsError(try WorkspaceProfile(
            kind: .web,
            entrypoint: "index.html",
            testConvention: .none,
            healthPath: "health?secret=value"
        ))
    }

    func testSnapshotOrderIsCanonicalAndIndependentOfInputOrder() throws {
        let first = WorkspaceSnapshotEntry(
            relativePath: "a.py",
            byteCount: 10,
            modifiedAtNanoseconds: 100,
            sha256: Data(repeating: 0xA1, count: 32)
        )
        let second = WorkspaceSnapshotEntry(
            relativePath: "z.py",
            byteCount: 20,
            modifiedAtNanoseconds: 200,
            sha256: Data(repeating: 0xB2, count: 32)
        )
        let manifest = Data(repeating: 0xCC, count: 32)

        let forward = try WorkspaceSnapshot(
            generation: 7,
            entries: [first, second],
            manifestSHA256: manifest
        )
        let reverse = try WorkspaceSnapshot(
            generation: 7,
            entries: [second, first],
            manifestSHA256: manifest
        )

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.entries.map(\.relativePath), ["a.py", "z.py"])
    }

    func testSnapshotRejectsDuplicatePathsAndInvalidDigests() {
        let invalidDigest = WorkspaceSnapshotEntry(
            relativePath: "main.py",
            byteCount: 1,
            modifiedAtNanoseconds: 1,
            sha256: Data(repeating: 0, count: 31)
        )
        XCTAssertThrowsError(try WorkspaceSnapshot(
            generation: 1,
            entries: [invalidDigest],
            manifestSHA256: Data(repeating: 0, count: 32)
        ))

        let valid = WorkspaceSnapshotEntry(
            relativePath: "main.py",
            byteCount: 1,
            modifiedAtNanoseconds: 1,
            sha256: Data(repeating: 0, count: 32)
        )
        XCTAssertThrowsError(try WorkspaceSnapshot(
            generation: 1,
            entries: [valid, valid],
            manifestSHA256: Data(repeating: 0, count: 32)
        ))
    }
}
