import Foundation
import XCTest
@testable import LiteTermCore

final class LocalShellTests: XCTestCase {
    private let fileManager = FileManager.default

    func testShellCreatesListsReadsCopiesMovesAndRequestsOneFileRemoval() async throws {
        let root = try makeRoot()
        let shell = LocalShell(rootURL: root)

        let madeDirectory = await shell.execute("mkdir docs")
        XCTAssertEqual(madeDirectory.outputLines, [])
        let changedDirectory = await shell.execute("cd docs")
        let expectedDocs = try canonical(root).appendingPathComponent("docs")
        XCTAssertEqual(changedDirectory.directoryChange, expectedDocs)
        let workingDirectory = await shell.execute("pwd")
        XCTAssertEqual(workingDirectory.outputLines, ["/docs"])
        let touched = await shell.execute("touch notes.txt")
        XCTAssertEqual(touched.outputLines, [])
        try "hello".data(using: .utf8)!.write(to: root.appendingPathComponent("docs/notes.txt"))
        let listing = await shell.execute("ls")
        XCTAssertEqual(listing.outputLines, ["notes.txt"])
        let content = await shell.execute("cat notes.txt")
        XCTAssertEqual(content.outputLines, ["hello"])
        let copied = await shell.execute("cp notes.txt copy.txt")
        XCTAssertEqual(copied.outputLines, [])
        let moved = await shell.execute("mv copy.txt moved.txt")
        XCTAssertEqual(moved.outputLines, [])
        let removal = await shell.execute("rm moved.txt")
        guard let request = removal.deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }
        let expectedTarget = try canonical(root).appendingPathComponent("docs/moved.txt")
        XCTAssertEqual(request.targetURL, expectedTarget)
        XCTAssertEqual(request.rootRelativePath, "docs/moved.txt")
        XCTAssertEqual(request.fileIdentity.isUsable, true)
        XCTAssertEqual(fileManager.fileExists(atPath: request.targetURL.path), true)

        let removed = await shell.confirmDeletion(request)
        XCTAssertEqual(removed.outputLines, [])
        XCTAssertEqual(fileManager.fileExists(atPath: request.targetURL.path), false)
    }

    func testCancelDeletionLeavesNonEmptyFileUntouched() async throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: target)
        let shell = LocalShell(rootURL: root)

        guard let request = (await shell.execute("rm notes.txt")).deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }
        await shell.cancelDeletion(request)

        XCTAssertEqual(fileManager.fileExists(atPath: target.path), true)
        let retainedText = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(retainedText, "keep me")
    }

    func testSupersededDeletionRequestCannotDeleteItsFile() async throws {
        let root = try makeRoot()
        let firstURL = root.appendingPathComponent("first.txt")
        let secondURL = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let shell = LocalShell(rootURL: root)

        guard
            let first = (await shell.execute("rm first.txt")).deletionConfirmationRequest,
            let second = (await shell.execute("rm second.txt")).deletionConfirmationRequest
        else {
            return XCTFail("rm must return deletion requests")
        }
        let staleResult = await shell.confirmDeletion(first)

        XCTAssertEqual(fileManager.fileExists(atPath: firstURL.path), true)
        XCTAssertEqual(fileManager.fileExists(atPath: secondURL.path), true)
        XCTAssertEqual(staleResult.outputLines, ["Error: deletion request expired"])

        _ = await shell.confirmDeletion(second)
        XCTAssertEqual(fileManager.fileExists(atPath: firstURL.path), true)
        XCTAssertEqual(fileManager.fileExists(atPath: secondURL.path), false)
    }

    func testDeletionConfirmationExpiresAfterSamePathFileReplacement() async throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("target.txt")
        let original = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: target)
        let shell = LocalShell(rootURL: root)
        guard let request = (await shell.execute("rm target.txt")).deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }

        try fileManager.moveItem(at: target, to: original)
        try Data("replacement".utf8).write(to: target)
        let result = await shell.confirmDeletion(request)
        let replacementText = try String(contentsOf: target, encoding: .utf8)
        let originalText = try String(contentsOf: original, encoding: .utf8)

        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(replacementText, "replacement")
        XCTAssertEqual(originalText, "original")
    }

    func testDeletionConfirmationExpiresAfterIntermediateDirectoryBecomesSymlinkToSameObject() async throws {
        let root = try makeRoot()
        let originalDirectory = root.appendingPathComponent("guarded", isDirectory: true)
        let relocatedDirectory = root.appendingPathComponent("relocated", isDirectory: true)
        try fileManager.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
        let target = originalDirectory.appendingPathComponent("target.txt")
        try Data("same object".utf8).write(to: target)
        let shell = LocalShell(rootURL: root)
        guard let request = (await shell.execute("rm guarded/target.txt")).deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }

        try fileManager.moveItem(at: originalDirectory, to: relocatedDirectory)
        try fileManager.createSymbolicLink(at: originalDirectory, withDestinationURL: relocatedDirectory)
        let result = await shell.confirmDeletion(request)
        let retainedText = try String(
            contentsOf: relocatedDirectory.appendingPathComponent("target.txt"),
            encoding: .utf8
        )

        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(retainedText, "same object")
    }

    func testDeletionConfirmationExpiresAfterTargetBecomesSymlink() async throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("target.txt")
        let relocated = root.appendingPathComponent("relocated.txt")
        try Data("same object".utf8).write(to: target)
        let shell = LocalShell(rootURL: root)
        guard let request = (await shell.execute("rm target.txt")).deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }

        try fileManager.moveItem(at: target, to: relocated)
        try fileManager.createSymbolicLink(at: target, withDestinationURL: relocated)
        let result = await shell.confirmDeletion(request)
        let symlinkDestination = try fileManager.destinationOfSymbolicLink(atPath: target.path)
        let retainedData = try Data(contentsOf: relocated)

        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(symlinkDestination, relocated.path)
        XCTAssertEqual(retainedData, Data("same object".utf8))
    }

    func testInjectedIdentityMismatchExpiresWithoutDeleting() async throws {
        let root = try makeRoot()
        let fileSystem = IdentityMismatchFileSystem()
        let shell = LocalShell(rootURL: root, fileSystem: fileSystem)
        guard let request = (await shell.execute("rm target.txt")).deletionConfirmationRequest else {
            return XCTFail("rm must return a deletion request")
        }

        let result = await shell.confirmDeletion(request)

        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(fileSystem.revalidationCallCount, 1)
        XCTAssertEqual(fileSystem.didDelete, false)
    }

    func testDeletionRequestExpiresWhenPreparationSeesTargetReplacedBySymlink() async throws {
        let root = try makeRoot()
        let fileSystem = RequestPreparationRaceFileSystem(rootURL: root)
        let shell = LocalShell(rootURL: root, fileSystem: fileSystem)

        let result = await shell.execute("rm target.txt")

        XCTAssertNil(result.deletionConfirmationRequest)
        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(fileSystem.prepareCallCount, 1)
    }

    func testShellRejectsInternallyMismatchedPreparedDeletion() async throws {
        let root = try makeRoot()
        let fileSystem = MismatchedPreparedDeletionFileSystem(rootURL: root)
        let shell = LocalShell(rootURL: root, fileSystem: fileSystem)

        let result = await shell.execute("rm target.txt")

        XCTAssertNil(result.deletionConfirmationRequest)
        XCTAssertEqual(result.outputLines, ["Error: deletion request expired"])
        XCTAssertEqual(fileSystem.prepareCallCount, 1)
    }

    func testShellRejectsRootAndDirectoryRemoval() async throws {
        let root = try makeRoot()
        try fileManager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let shell = LocalShell(rootURL: root)

        let rootRemoval = await shell.execute("rm /")
        let directoryRemoval = await shell.execute("rm docs")

        XCTAssertEqual(rootRemoval.outputLines, ["Error: workspace root cannot be removed"])
        XCTAssertEqual(directoryRemoval.outputLines, ["Error: directories cannot be removed"])
        XCTAssertEqual(fileManager.fileExists(atPath: root.path), true)
        XCTAssertEqual(fileManager.fileExists(atPath: root.appendingPathComponent("docs").path), true)
    }

    func testShellReportsEditorURLAndClearRequest() async throws {
        let root = try makeRoot()
        let shell = LocalShell(rootURL: root)
        _ = await shell.execute("touch draft.txt")

        let edit = await shell.execute("edit draft.txt")
        let clear = await shell.execute("clear")
        let expectedDraft = try canonical(root).appendingPathComponent("draft.txt")

        XCTAssertEqual(edit.editorURL, expectedDraft)
        XCTAssertEqual(clear.clearRequested, true)
        XCTAssertEqual(clear.outputLines, [])
    }

    func testShellReturnsTypedWorkspaceActionsWithoutLaunchingAProcess() async throws {
        let root = try makeTemporaryDirectory()
        let shell = LocalShell(rootURL: root)
        let cases: [(String, WorkspaceShellAction)] = [
            ("workspace", .showStatus),
            ("check", .check),
            ("test", .test),
            ("run", .run),
            ("stop", .stop),
            ("problems", .showProblems),
            ("ports", .showPorts)
        ]

        for (command, expectedAction) in cases {
            let execution = await shell.execute(command)
            XCTAssertEqual(execution.workspaceAction, expectedAction)
            XCTAssertTrue(execution.outputLines.isEmpty)
            XCTAssertNil(execution.editorURL)
            XCTAssertNil(execution.deletionConfirmationRequest)
        }
    }

    func testShellRejectsDirectoryEditing() async throws {
        let root = try makeRoot()
        try fileManager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: false)
        let shell = LocalShell(rootURL: root)

        let edit = await shell.execute("edit docs")

        XCTAssertNil(edit.editorURL)
        XCTAssertEqual(edit.outputLines, ["Error: target is not a regular file"])
    }

    func testCatEmptyFileProducesNoOutputLines() async throws {
        let root = try makeRoot()
        let shell = LocalShell(rootURL: root)
        _ = await shell.execute("touch empty.txt")

        let content = await shell.execute("cat empty.txt")

        XCTAssertEqual(content.outputLines, [])
    }

    func testShellUsesInjectedFileAccessBoundary() async throws {
        let root = try makeRoot()
        let shell = LocalShell(rootURL: root, fileSystem: FixtureFileSystem())

        let listing = await shell.execute("ls")

        XCTAssertEqual(listing.outputLines, ["coordinated-entry"])
    }

    func testShellEnforcesExactFiveMiBReadAndEditCeiling() async throws {
        let root = try makeRoot()
        let shell = LocalShell(rootURL: root)
        let atLimit = root.appendingPathComponent("at-limit.txt")
        let aboveLimit = root.appendingPathComponent("above-limit.txt")
        try Data(repeating: 0x61, count: 5 * 1024 * 1024).write(to: atLimit)
        try Data(repeating: 0x61, count: 5 * 1024 * 1024 + 1).write(to: aboveLimit)

        let allowedEdit = await shell.execute("edit at-limit.txt")
        let rejectedRead = await shell.execute("cat above-limit.txt")
        let rejectedEdit = await shell.execute("edit above-limit.txt")
        let expectedAtLimit = try canonical(root).appendingPathComponent("at-limit.txt")

        XCTAssertEqual(allowedEdit.editorURL, expectedAtLimit)
        XCTAssertEqual(rejectedRead.outputLines, ["Error: file exceeds the 5 MiB read/edit limit"])
        XCTAssertEqual(rejectedEdit.outputLines, ["Error: file exceeds the 5 MiB read/edit limit"])
    }

    func testReadConsumesOnlyLimitPlusProbeByteFromGrowingSourceAndClosesHandle() throws {
        let root = try makeRoot()
        let handle = GrowingReadHandle(
            availableByteCount: LocalFileSystem.maximumTextFileBytes + 64 * 1024
        )
        let fileSystem = LocalFileSystem(rootURL: root, openFileForReading: { _ in handle })

        do {
            _ = try fileSystem.readText(at: root.appendingPathComponent("growing.txt"))
            XCTFail("A source larger than 5 MiB must be rejected")
        } catch LocalFileSystemError.fileTooLarge {
            // Expected.
        } catch {
            XCTFail("Expected fileTooLarge, received \(error)")
        }

        XCTAssertEqual(handle.totalBytesReturned, LocalFileSystem.maximumTextFileBytes + 1)
        XCTAssertEqual(handle.maximumRequestedCount <= 64 * 1024, true)
        XCTAssertEqual(handle.isClosed, true)
    }

    private func makeRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("LiteTerm-LocalShellTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func canonical(_ url: URL) throws -> URL {
        try WorkspacePathResolver(rootURL: url, currentDirectoryURL: url).resolve("/")
    }
}

private struct FixtureFileSystem: LocalFileSystemAccess {
    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { true }
    func list(at url: URL) throws -> [String] { ["coordinated-entry"] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        throw LocalFileSystemError.deletionRequestExpired
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        throw LocalFileSystemError.fileIdentityUnavailable
    }
    func revalidateAndRemoveFile(
        rootURL: URL,
        rootRelativePath: String,
        expectedIdentity: LocalFileIdentity
    ) throws {
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private final class IdentityMismatchFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private(set) var revalidationCallCount = 0
    private(set) var didDelete = false

    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        PreparedDeletion(
            targetURL: rootURL.appendingPathComponent(userPath),
            rootRelativePath: userPath,
            fileIdentity: LocalFileIdentity(resourceIdentifier: Data([0x01]))
        )
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x01]))
    }

    func revalidateAndRemoveFile(
        rootURL: URL,
        rootRelativePath: String,
        expectedIdentity: LocalFileIdentity
    ) throws {
        revalidationCallCount += 1
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private final class RequestPreparationRaceFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private let rootURL: URL
    private var replacementIsSymlink = false
    private(set) var prepareCallCount = 0

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func symbolicLinkDestination(at url: URL) throws -> String? {
        guard url.lastPathComponent == "target.txt" else { return nil }
        return replacementIsSymlink ? "replacement.txt" : nil
    }

    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x02]))
    }
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        prepareCallCount += 1
        let resolver = WorkspacePathResolver(
            rootURL: rootURL,
            currentDirectoryURL: currentDirectoryURL,
            pathInspector: self
        )
        _ = try resolver.resolveWithoutSymbolicLinks(userPath)
        replacementIsSymlink = true
        do {
            _ = try resolver.resolveWithoutSymbolicLinks(userPath)
            XCTFail("the replacement symlink must not resolve as the original lexical target")
        } catch {
            throw LocalFileSystemError.deletionRequestExpired
        }
        throw LocalFileSystemError.deletionRequestExpired
    }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {
        XCTFail("an expired request must not reach confirmation")
    }
}

private final class MismatchedPreparedDeletionFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private let rootURL: URL
    private(set) var prepareCallCount = 0

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x03]))
    }
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        prepareCallCount += 1
        return PreparedDeletion(
            targetURL: rootURL.appendingPathComponent("target.txt"),
            rootRelativePath: "replacement.txt",
            fileIdentity: LocalFileIdentity(resourceIdentifier: Data([0x03]))
        )
    }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {}
}

private final class GrowingReadHandle: LocalFileReadHandle, @unchecked Sendable {
    private let availableByteCount: Int
    private(set) var totalBytesReturned = 0
    private(set) var maximumRequestedCount = 0
    private(set) var isClosed = false

    init(availableByteCount: Int) {
        self.availableByteCount = availableByteCount
    }

    func read(upToCount count: Int) throws -> Data {
        maximumRequestedCount = max(maximumRequestedCount, count)
        let byteCount = min(count, availableByteCount - totalBytesReturned)
        guard byteCount > 0 else { return Data() }
        totalBytesReturned += byteCount
        return Data(repeating: 0x61, count: byteCount)
    }

    func close() throws {
        isClosed = true
    }
}
