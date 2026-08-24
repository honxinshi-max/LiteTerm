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
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity
    func revalidateAndRemoveFile(
        rootURL: URL,
        rootRelativePath: String,
        expectedIdentity: LocalFileIdentity
    ) throws
}

public struct LocalFileIdentity: Equatable, Sendable {
    public let resourceIdentifier: Data?
    public let deviceNumber: UInt64?
    public let fileNumber: UInt64?

    public init(
        resourceIdentifier: Data? = nil,
        deviceNumber: UInt64? = nil,
        fileNumber: UInt64? = nil
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.deviceNumber = deviceNumber
        self.fileNumber = fileNumber
    }

    public var isUsable: Bool {
        resourceIdentifier != nil || (deviceNumber != nil && fileNumber != nil)
    }
}

public enum LocalFileSystemError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidText
    case notRegularFile
    case fileIdentityUnavailable
    case deletionRequestExpired
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

    public func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalFileSystemError.notRegularFile
        }

        let resourceValues = try url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
            throw LocalFileSystemError.notRegularFile
        }

        let resourceIdentifier = try resourceValues.fileResourceIdentifier.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        let identity = LocalFileIdentity(
            resourceIdentifier: resourceIdentifier,
            deviceNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        guard identity.isUsable else {
            throw LocalFileSystemError.fileIdentityUnavailable
        }
        return identity
    }

    public func revalidateAndRemoveFile(
        rootURL: URL,
        rootRelativePath: String,
        expectedIdentity: LocalFileIdentity
    ) throws {
        guard !rootRelativePath.isEmpty, expectedIdentity.isUsable else {
            throw LocalFileSystemError.deletionRequestExpired
        }

        let currentFileSystem = LocalFileSystem(rootURL: rootURL)
        let resolver = WorkspacePathResolver(
            rootURL: rootURL,
            currentDirectoryURL: rootURL,
            pathInspector: currentFileSystem
        )
        let target: URL
        do {
            target = try resolver.resolveWithoutSymbolicLinks(rootRelativePath)
        } catch {
            throw LocalFileSystemError.deletionRequestExpired
        }
        guard target.path != resolver.rootURL.path else {
            throw LocalFileSystemError.workspaceRootRemoval
        }

        let currentIdentity: LocalFileIdentity
        do {
            currentIdentity = try currentFileSystem.deletionIdentity(at: target)
        } catch {
            throw LocalFileSystemError.deletionRequestExpired
        }
        guard currentIdentity == expectedIdentity else {
            throw LocalFileSystemError.deletionRequestExpired
        }

        // FileManager has no portable iOS/File Provider descriptor-relative delete API.
        // Revalidation is fail-closed; a final OS-level race remains between this check and removal.
        try FileManager.default.removeItem(at: target)
    }

    private func validateTextSize(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumTextFileBytes else {
            throw LocalFileSystemError.fileTooLarge
        }
    }
}
