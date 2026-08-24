import Foundation
import XCTest
@testable import LiteTermCore

final class WorkspacePathResolverTests: XCTestCase {
    private let fileManager = FileManager.default

    func testResolverKeepsRelativePathInsideWorkspace() throws {
        let root = try makeDirectory(named: "workspace")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: nested)

        let resolved = try resolver.resolve("../note.txt")
        let expected = try canonical(root).appendingPathComponent("note.txt")

        XCTAssertEqual(resolved, expected)
    }

    func testResolverRejectsParentTraversalOutsideWorkspace() throws {
        let root = try makeDirectory(named: "workspace")
        let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: root)

        XCTAssertResolverError(try resolver.resolve("../outside.txt"), equals: .outsideWorkspace)
    }

    func testResolverTreatsAbsoluteInputAsWorkspaceVirtualPath() throws {
        let root = try makeDirectory(named: "workspace")
        let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: root)

        let resolved = try resolver.resolve("/documents/readme.txt")
        let expected = try canonical(root).appendingPathComponent("documents/readme.txt")

        XCTAssertEqual(resolved, expected)
        XCTAssertEqual(resolver.displayPath(for: resolved), "/documents/readme.txt")
    }

    func testResolverRejectsSymlinkEscapeForNonexistentLeaf() throws {
        let root = try makeDirectory(named: "workspace")
        let sibling = try makeDirectory(named: "sibling")
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: sibling)
        let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: root)

        XCTAssertResolverError(try resolver.resolve("escape/secret.txt"), equals: .outsideWorkspace)
    }

    func testResolverDoesNotUseStringPrefixForContainment() throws {
        let parent = try makeDirectory(named: "parent")
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let siblingWithSharedPrefix = parent.appendingPathComponent("workspace-copy", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: siblingWithSharedPrefix, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("prefix-escape"), withDestinationURL: siblingWithSharedPrefix)
        let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: root)

        XCTAssertResolverError(try resolver.resolve("prefix-escape/file.txt"), equals: .outsideWorkspace)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LiteTerm-WorkspacePathResolverTests-\(UUID().uuidString)-\(name)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func canonical(_ url: URL) throws -> URL {
        try WorkspacePathResolver(rootURL: url, currentDirectoryURL: url).resolve("/")
    }

    private func XCTAssertResolverError(
        _ operation: @autoclosure () throws -> URL,
        equals expected: WorkspacePathResolverError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try operation()
            XCTFail("Expected resolver error", file: file, line: line)
        } catch let error as WorkspacePathResolverError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
