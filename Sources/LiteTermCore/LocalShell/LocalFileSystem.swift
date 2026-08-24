import Foundation

public protocol WorkspacePathInspecting: Sendable {
    func symbolicLinkDestination(at url: URL) throws -> String?
    func isDirectory(at url: URL) throws -> Bool
}

public protocol LocalFileSystemAccess: WorkspacePathInspecting {
    func list(at url: URL) throws -> [String]
    func readText(at url: URL) throws -> String
    func prepareForEditing(at url: URL) throws
    func createDirectory(at url: URL) throws
    func touch(at url: URL) throws
    func copyItem(from source: URL, to destination: URL) throws
    func moveItem(from source: URL, to destination: URL) throws
    func removeFile(at url: URL) throws
}

public enum LocalFileSystemError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidText
    case notRegularFile
    case workspaceRootRemoval
    case directoryRemoval
}

public struct LocalFileSystem: LocalFileSystemAccess {
    public static let maximumTextFileBytes = 5 * 1024 * 1024

    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func symbolicLinkDestination(at url: URL) throws -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public func isDirectory(at url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return isDirectory.boolValue
    }

    public func list(at url: URL) throws -> [String] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            return [url.lastPathComponent]
        }
        return try fileManager.contentsOfDirectory(atPath: url.path).sorted()
    }

    public func readText(at url: URL) throws -> String {
        try validateTextSize(at: url)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalFileSystemError.invalidText
        }
        return text
    }

    public func prepareForEditing(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !isDirectory.boolValue else {
            throw LocalFileSystemError.notRegularFile
        }
        try validateTextSize(at: url)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func touch(at url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return
        }
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func copyItem(from source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func moveItem(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func removeFile(at url: URL) throws {
        guard url.path != rootURL.path else {
            throw LocalFileSystemError.workspaceRootRemoval
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !isDirectory.boolValue else {
            throw LocalFileSystemError.directoryRemoval
        }
        try FileManager.default.removeItem(at: url)
    }

    private func validateTextSize(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumTextFileBytes else {
            throw LocalFileSystemError.fileTooLarge
        }
    }
}
