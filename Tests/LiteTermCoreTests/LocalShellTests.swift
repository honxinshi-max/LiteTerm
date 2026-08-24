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
    func removeFile(at url: URL) throws {}
}
