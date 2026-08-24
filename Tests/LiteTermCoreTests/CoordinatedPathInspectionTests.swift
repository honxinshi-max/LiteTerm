import Foundation
import XCTest
@testable import LiteTermCore

final class CoordinatedPathInspectionTests: XCTestCase {
    func testResolverUsesInjectedInspectionToRejectSymlinkEscape() {
        let root = URL(fileURLWithPath: "/tmp/LiteTerm-inspected-root-\(UUID().uuidString)", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/LiteTerm-inspected-outside-\(UUID().uuidString)", isDirectory: true)
        let fileSystem = InspectingFileSystem(
            symbolicLinks: [root.appendingPathComponent("escape").path: outside.path]
        )
        let resolver = WorkspacePathResolver(
            rootURL: root,
            currentDirectoryURL: root,
            pathInspector: fileSystem
        )

        do {
            _ = try resolver.resolve("escape/secret.txt")
            XCTFail("Injected symlink inspection must preserve the workspace boundary")
        } catch WorkspacePathResolverError.outsideWorkspace {
            XCTAssertEqual(fileSystem.inspectedSymbolicLinkPaths().contains(root.appendingPathComponent("escape").path), true)
        } catch {
            XCTFail("Expected outsideWorkspace, received \(error)")
        }
    }

    func testChangeDirectoryUsesInjectedDirectoryInspection() async {
        let root = URL(fileURLWithPath: "/tmp/LiteTerm-inspected-cd-\(UUID().uuidString)", isDirectory: true)
        let fileSystem = InspectingFileSystem()
        let shell = LocalShell(rootURL: root, fileSystem: fileSystem)

        let execution = await shell.execute("cd virtual-folder")

        XCTAssertEqual(execution.outputLines, [])
        XCTAssertEqual(execution.directoryChange?.path, root.appendingPathComponent("virtual-folder").path)
        XCTAssertEqual(fileSystem.inspectedDirectoryPaths(), [root.appendingPathComponent("virtual-folder").path])
    }
}

private final class InspectingFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let symbolicLinks: [String: String]
    private var symbolicLinkPaths: [String] = []
    private var directoryPaths: [String] = []

    init(symbolicLinks: [String: String] = [:]) {
        self.symbolicLinks = symbolicLinks
    }

    func symbolicLinkDestination(at url: URL) throws -> String? {
        lock.lock()
        symbolicLinkPaths.append(url.path)
        lock.unlock()
        return symbolicLinks[url.path]
    }

    func isDirectory(at url: URL) throws -> Bool {
        lock.lock()
        directoryPaths.append(url.path)
        lock.unlock()
        return true
    }

    func inspectedSymbolicLinkPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return symbolicLinkPaths
    }

    func inspectedDirectoryPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return directoryPaths
    }

    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func removeFile(at url: URL) throws {}
}
