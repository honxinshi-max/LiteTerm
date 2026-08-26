import XCTest
@testable import LiteTermCore

final class WorkspaceInventoryPolicyTests: XCTestCase {
    private let policy = WorkspaceInventoryPolicy()

    func testAcceptsContainedSourceAndExcludesSensitiveOrGeneratedEntries() {
        let result = policy.evaluate([
            file("Sources/main.swift", bytes: 100),
            file(".git/config", bytes: 100),
            file("node_modules/library.js", bytes: 100),
            file("credentials.json", bytes: 100),
            file("image.png", bytes: 100),
            file("escape.py", bytes: 100, symbolicLink: true, targetContained: false),
            file("shared.py", bytes: 100, symbolicLink: true, targetContained: true)
        ])

        XCTAssertEqual(result.acceptedFiles.map(\.relativePath), ["Sources/main.swift", "shared.py"])
        XCTAssertEqual(Set(result.exclusions.map(\.reason)), [
            .hidden,
            .generatedOrCache,
            .credentialLike,
            .binary,
            .symbolicLinkEscape
        ])
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testRejectsMalformedAndDuplicateRelativePaths() {
        let result = policy.evaluate([
            file("../escape.py", bytes: 10),
            file("/absolute.py", bytes: 10),
            file("main.py", bytes: 10),
            file("main.py", bytes: 10)
        ])

        XCTAssertEqual(Set(result.violations), [
            .invalidRelativePath,
            .duplicateRelativePath
        ])
    }

    func testEntryCountLimitIsAVisibleFailure() {
        let entries = (0...1_000).map { file("Source/\($0).swift", bytes: 1) }
        let result = policy.evaluate(entries)

        XCTAssertEqual(result.violations, [.entryCountExceeded(limit: 1_000)])
    }

    func testSingleFileLimitIsAVisibleFailure() {
        let result = policy.evaluate([
            file("large.py", bytes: 5 * 1_024 * 1_024 + 1)
        ])

        XCTAssertEqual(result.violations, [.fileBytesExceeded(limit: 5 * 1_024 * 1_024)])
    }

    func testTotalSourceLimitIsAVisibleFailure() {
        let fourMiB = 4 * 1_024 * 1_024
        let entries = (0..<5).map { file("Source/\($0).swift", bytes: fourMiB) }
            + [file("Source/overflow.swift", bytes: 1)]
        let result = policy.evaluate(entries)

        XCTAssertEqual(result.violations, [.totalSourceBytesExceeded(limit: 20 * 1_024 * 1_024)])
    }

    private func file(
        _ relativePath: String,
        bytes: Int,
        symbolicLink: Bool = false,
        targetContained: Bool = false
    ) -> WorkspaceInventoryEntry {
        WorkspaceInventoryEntry(
            relativePath: relativePath,
            byteCount: bytes,
            isDirectory: false,
            isRegularFile: true,
            isSymbolicLink: symbolicLink,
            symbolicLinkTargetIsInsideRoot: targetContained
        )
    }
}
