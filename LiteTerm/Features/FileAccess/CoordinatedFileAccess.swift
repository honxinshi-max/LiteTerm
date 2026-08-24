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

enum CoordinatedFileAccess {
    static let maximumBytes = LocalFileSystem.maximumTextFileBytes

    static func readText(from url: URL) throws -> String {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<String, Error>?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                let values = try coordinatedURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values.isDirectory != true else {
                    throw CoordinatedFileAccessError.notRegularFile
                }
                if let size = values.fileSize, size > maximumBytes {
                    throw CoordinatedFileAccessError.fileTooLarge
                }
                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard data.count <= maximumBytes else {
                    throw CoordinatedFileAccessError.fileTooLarge
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CoordinatedFileAccessError.invalidText
                }
                return text
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

    static func writeText(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else {
            throw CoordinatedFileAccessError.fileTooLarge
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
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
}

struct CoordinatedLocalFileSystem: LocalFileSystemAccess {
    private let directFileSystem: LocalFileSystem

    init(rootURL: URL) {
        directFileSystem = LocalFileSystem(rootURL: rootURL)
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

    func removeFile(at url: URL) throws {
        try coordinateWrite(at: url, options: .forDeleting) {
            try directFileSystem.removeFile(at: $0)
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
}

private final class CoordinationResultBox<Value>: @unchecked Sendable {
    var value: Result<Value, Error>?
}
