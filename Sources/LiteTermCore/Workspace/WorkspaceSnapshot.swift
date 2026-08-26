import Foundation

public struct WorkspaceSnapshotEntry: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let modifiedAtNanoseconds: Int64
    public let sha256: Data

    public init(
        relativePath: String,
        byteCount: Int,
        modifiedAtNanoseconds: Int64,
        sha256: Data
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAtNanoseconds = modifiedAtNanoseconds
        self.sha256 = sha256
    }
}

public enum WorkspaceSnapshotError: Error, Equatable, Sendable {
    case invalidEntry
    case duplicateRelativePath
    case invalidManifestDigest
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let entries: [WorkspaceSnapshotEntry]
    public let manifestSHA256: Data

    public init(
        generation: UInt64,
        entries: [WorkspaceSnapshotEntry],
        manifestSHA256: Data
    ) throws {
        guard manifestSHA256.count == 32 else {
            throw WorkspaceSnapshotError.invalidManifestDigest
        }

        var paths: Set<String> = []
        for entry in entries {
            guard
                WorkspaceRelativePathPolicy.isValidFilePath(entry.relativePath),
                entry.byteCount >= 0,
                entry.sha256.count == 32
            else {
                throw WorkspaceSnapshotError.invalidEntry
            }
            guard paths.insert(entry.relativePath).inserted else {
                throw WorkspaceSnapshotError.duplicateRelativePath
            }
        }

        self.generation = generation
        self.entries = entries.sorted { $0.relativePath < $1.relativePath }
        self.manifestSHA256 = manifestSHA256
    }
}
