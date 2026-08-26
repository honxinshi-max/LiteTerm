import Foundation
import LiteTermCore

enum CoordinatedFileAccessError: LocalizedError {
    case fileTooLarge
    case invalidText
    case notRegularFile
    case coordinationFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The file exceeds the 5 MiB edit limit."
        case .invalidText:
            return "The file is not valid UTF-8 text."
        case .notRegularFile:
            return "Only regular files can be edited."
        case .coordinationFailed:
            return "The file provider did not complete the operation."
        }
    }
}

protocol LocalDeletionCoordinating: Sendable {
    func coordinateDeletion(
        at requestedURL: URL,
        accessor: (URL) throws -> Void
    ) throws
}

private struct FoundationLocalDeletionCoordinator: LocalDeletionCoordinating {
    func coordinateDeletion(
        at requestedURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let result = CoordinationResultBox<Void>()
        coordinator.coordinate(
            writingItemAt: requestedURL,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            result.value = Result { try accessor(coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let value = result.value else {
            throw CoordinatedFileAccessError.coordinationFailed
        }
        try value.get()
    }
}

enum CoordinatedFileAccess {
    static let maximumBytes = LocalFileSystem.maximumTextFileBytes

    static func readText(
        from url: URL,
        openFileForReading: LocalFileReadHandleFactory? = nil,
        inside rootURL: URL? = nil
    ) throws -> String {
        if let rootURL, !isContained(url, inside: rootURL) {
            throw CoordinatedFileAccessError.notRegularFile
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<String, Error>?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                if let rootURL, !isContained(coordinatedURL, inside: rootURL) {
                    throw CoordinatedFileAccessError.notRegularFile
                }
                let values = try coordinatedURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values.isDirectory != true else {
                    throw CoordinatedFileAccessError.notRegularFile
                }
                if let size = values.fileSize, size > maximumBytes {
                    throw CoordinatedFileAccessError.fileTooLarge
                }
                let fileSystem: LocalFileSystem
                if let openFileForReading {
                    fileSystem = LocalFileSystem(
                        rootURL: coordinatedURL.deletingLastPathComponent(),
                        openFileForReading: openFileForReading
                    )
                } else {
                    fileSystem = LocalFileSystem(
                        rootURL: coordinatedURL.deletingLastPathComponent()
                    )
                }
                do {
                    return try fileSystem.readText(at: coordinatedURL)
                } catch LocalFileSystemError.fileTooLarge {
                    throw CoordinatedFileAccessError.fileTooLarge
                } catch LocalFileSystemError.invalidText {
                    throw CoordinatedFileAccessError.invalidText
                } catch LocalFileSystemError.notRegularFile {
                    throw CoordinatedFileAccessError.notRegularFile
                }
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CoordinatedFileAccessError.coordinationFailed
        }
        return try result.get()
    }

    static func writeText(_ text: String, to url: URL, inside rootURL: URL? = nil) throws {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else {
            throw CoordinatedFileAccessError.fileTooLarge
        }
        if let rootURL, !isContained(url, inside: rootURL) {
            throw CoordinatedFileAccessError.notRegularFile
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                if let rootURL, !isContained(coordinatedURL, inside: rootURL) {
                    throw CoordinatedFileAccessError.notRegularFile
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: coordinatedURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw CoordinatedFileAccessError.notRegularFile
                }
                try data.write(to: coordinatedURL, options: .atomic)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CoordinatedFileAccessError.coordinationFailed
        }
        try result.get()
    }

    private static func isContained(_ itemURL: URL, inside rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let itemComponents = itemURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard itemComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, itemComponents).allSatisfy(==)
    }
}

struct CoordinatedLocalFileSystem: LocalFileSystemAccess {
    private let rootURL: URL
    private let directFileSystem: LocalFileSystem
    private let deletionCoordinator: any LocalDeletionCoordinating

    init(
        rootURL: URL,
        deletionCoordinator: any LocalDeletionCoordinating = FoundationLocalDeletionCoordinator()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        directFileSystem = LocalFileSystem(rootURL: rootURL)
        self.deletionCoordinator = deletionCoordinator
    }

    func symbolicLinkDestination(at url: URL) throws -> String? {
        let standardizedURL = url.standardizedFileURL
        if standardizedURL == rootURL {
            return try coordinateRead(at: standardizedURL) {
                try directFileSystem.symbolicLinkDestination(at: $0)
            }
        }

        if isContained(standardizedURL, by: rootURL) {
            let parentURL = standardizedURL.deletingLastPathComponent()
            return try coordinateRead(at: parentURL) { coordinatedParentURL in
                try directFileSystem.symbolicLinkDestination(
                    at: coordinatedParentURL.appendingPathComponent(standardizedURL.lastPathComponent)
                )
            }
        }

        return try coordinateRead(at: standardizedURL) {
            try directFileSystem.symbolicLinkDestination(at: $0)
        }
    }

    func isDirectory(at url: URL) throws -> Bool {
        try coordinateRead(at: url) { try directFileSystem.isDirectory(at: $0) }
    }

    func list(at url: URL) throws -> [String] {
        try coordinateRead(at: url) { try directFileSystem.list(at: $0) }
    }

    func readText(at url: URL) throws -> String {
        try coordinateRead(at: url) { try directFileSystem.readText(at: $0) }
    }

    func prepareForEditing(at url: URL) throws {
        try coordinateRead(at: url) { try directFileSystem.prepareForEditing(at: $0) }
    }

    func createDirectory(at url: URL) throws {
        try coordinateWrite(at: url, options: .forReplacing) {
            try directFileSystem.createDirectory(at: $0)
        }
    }

    func touch(at url: URL) throws {
        try coordinateWrite(at: url, options: .forReplacing) {
            try directFileSystem.touch(at: $0)
        }
    }

    func copyItem(from source: URL, to destination: URL) throws {
        try coordinate(
            reading: source,
            writing: destination,
            writingOptions: .forReplacing
        ) { coordinatedSource, coordinatedDestination in
            try directFileSystem.copyItem(from: coordinatedSource, to: coordinatedDestination)
        }
    }

    func moveItem(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let result = CoordinationResultBox<Void>()
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            result.value = Result {
                try directFileSystem.moveItem(from: coordinatedSource, to: coordinatedDestination)
            }
        }
        try resolve(result, coordinationError: coordinationError)
    }

    func prepareDeletion(
        rootURL: URL,
        currentDirectoryURL: URL,
        userPath: String
    ) throws -> PreparedDeletion {
        let lexicalTarget = try lexicalTarget(
            rootURL: rootURL,
            currentDirectoryURL: currentDirectoryURL,
            userPath: userPath
        )
        return try coordinateRead(at: lexicalTarget) { coordinatedTargetURL in
            guard coordinatedTargetURL.path == lexicalTarget.path else {
                throw LocalFileSystemError.deletionRequestExpired
            }
            let prepared = try directFileSystem.prepareDeletion(
                rootURL: rootURL,
                currentDirectoryURL: currentDirectoryURL,
                userPath: userPath
            )
            guard prepared.targetURL.path == lexicalTarget.path else {
                throw LocalFileSystemError.deletionRequestExpired
            }
            return prepared
        }
    }

    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        try coordinateRead(at: url) { try directFileSystem.deletionIdentity(at: $0) }
    }

    func revalidateAndRemoveFile(
        rootURL: URL,
        rootRelativePath: String,
        expectedIdentity: LocalFileIdentity
    ) throws {
        let pathComponents = rootRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !pathComponents.isEmpty else {
            throw LocalFileSystemError.deletionRequestExpired
        }
        let targetURL = pathComponents.reduce(rootURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }

        let expectedTargetURL = targetURL.standardizedFileURL
        try deletionCoordinator.coordinateDeletion(at: expectedTargetURL) { coordinatedTargetURL in
            guard coordinatedTargetURL.standardizedFileURL.path == expectedTargetURL.path else {
                throw LocalFileSystemError.deletionRequestExpired
            }
            try LocalFileSystem(rootURL: rootURL).revalidateAndRemoveFile(
                rootURL: rootURL,
                rootRelativePath: rootRelativePath,
                expectedIdentity: expectedIdentity
            )
        }
    }

    private func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let result = CoordinationResultBox<T>()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result.value = Result { try accessor(coordinatedURL) }
        }
        return try resolve(result, coordinationError: coordinationError)
    }

    private func coordinateWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        accessor: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let result = CoordinationResultBox<Void>()
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            result.value = Result { try accessor(coordinatedURL) }
        }
        try resolve(result, coordinationError: coordinationError)
    }

    private func coordinate(
        reading source: URL,
        writing destination: URL,
        writingOptions: NSFileCoordinator.WritingOptions,
        accessor: (URL, URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let result = CoordinationResultBox<Void>()
        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: writingOptions,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            result.value = Result { try accessor(coordinatedSource, coordinatedDestination) }
        }
        try resolve(result, coordinationError: coordinationError)
    }

    private func resolve<T>(
        _ result: CoordinationResultBox<T>,
        coordinationError: NSError?
    ) throws -> T {
        if let coordinationError {
            throw coordinationError
        }
        guard let value = result.value else {
            throw CoordinatedFileAccessError.coordinationFailed
        }
        return try value.get()
    }

    private func isContained(_ url: URL, by root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    private func lexicalTarget(
        rootURL: URL,
        currentDirectoryURL: URL,
        userPath: String
    ) throws -> URL {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let currentComponents = currentDirectoryURL.standardizedFileURL.pathComponents
        guard currentComponents.count >= rootComponents.count,
              zip(rootComponents, currentComponents).allSatisfy(==) else {
            throw WorkspacePathResolverError.outsideWorkspace
        }

        var components = userPath.hasPrefix("/") ? rootComponents : currentComponents
        for component in userPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                guard components.count > rootComponents.count else {
                    throw WorkspacePathResolverError.outsideWorkspace
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        let target = URL(fileURLWithPath: NSString.path(withComponents: components))
        guard isContained(target, by: rootURL.standardizedFileURL) else {
            throw WorkspacePathResolverError.outsideWorkspace
        }
        return target
    }
}

private final class CoordinationResultBox<Value>: @unchecked Sendable {
    var value: Result<Value, Error>?
}
