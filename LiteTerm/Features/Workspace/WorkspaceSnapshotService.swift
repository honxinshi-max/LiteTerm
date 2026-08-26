import CryptoKit
import Foundation
import LiteTermCore

public enum WorkspaceCapturedSnapshotError: Error, Equatable, Sendable {
    case contentSetMismatch
    case contentDigestMismatch
}

public struct WorkspaceCapturedSnapshot: Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    private let contents: [String: Data]

    public init(snapshot: WorkspaceSnapshot, contents: [String: Data]) throws {
        guard Set(contents.keys) == Set(snapshot.entries.map(\.relativePath)) else {
            throw WorkspaceCapturedSnapshotError.contentSetMismatch
        }
        for entry in snapshot.entries {
            guard
                let content = contents[entry.relativePath],
                content.count == entry.byteCount,
                Data(SHA256.hash(data: content)) == entry.sha256
            else {
                throw WorkspaceCapturedSnapshotError.contentDigestMismatch
            }
        }
        self.snapshot = snapshot
        self.contents = contents
    }

    public var relativePaths: [String] { snapshot.entries.map(\.relativePath) }
    public var totalByteCount: Int { contents.values.reduce(0) { $0 + $1.count } }

    public func content(relativePath: String) -> Data? {
        contents[relativePath]
    }
}

public actor WorkspaceSnapshotService {
    public init() {}

    public func capture(
        generation: UInt64,
        rootURL: URL,
        evaluation: WorkspaceInventoryEvaluation
    ) throws -> WorkspaceSnapshot {
        try captureBundle(
            generation: generation,
            rootURL: rootURL,
            evaluation: evaluation
        ).snapshot
    }

    public func captureBundle(
        generation: UInt64,
        rootURL: URL,
        evaluation: WorkspaceInventoryEvaluation
    ) throws -> WorkspaceCapturedSnapshot {
        guard evaluation.violations.isEmpty else {
            throw WorkspaceFileServiceError.inventoryRejected
        }

        var capturedEntries: [CapturedEntry] = []
        capturedEntries.reserveCapacity(evaluation.acceptedFiles.count)
        for inventoryEntry in evaluation.acceptedFiles {
            let requestedURL = inventoryEntry.relativePath
                .split(separator: "/")
                .reduce(rootURL) { $0.appendingPathComponent(String($1)) }
            let snapshotEntry = try WorkspaceCoordinatedRead.perform(at: requestedURL) {
                coordinatedURL in
                try Self.captureEntry(
                    inventoryEntry,
                    coordinatedURL: coordinatedURL,
                    rootURL: rootURL
                )
            }
            capturedEntries.append(snapshotEntry)
        }

        let canonicalEntries = capturedEntries.sorted {
            $0.snapshotEntry.relativePath < $1.snapshotEntry.relativePath
        }
        let snapshotEntries = canonicalEntries.map(\.snapshotEntry)
        let snapshot = try WorkspaceSnapshot(
            generation: generation,
            entries: snapshotEntries,
            manifestSHA256: Self.manifestDigest(entries: snapshotEntries)
        )
        return try WorkspaceCapturedSnapshot(
            snapshot: snapshot,
            contents: Dictionary(
                uniqueKeysWithValues: canonicalEntries.map {
                    ($0.snapshotEntry.relativePath, $0.content)
                }
            )
        )
    }

    private struct CapturedEntry {
        let snapshotEntry: WorkspaceSnapshotEntry
        let content: Data
    }

    private static func captureEntry(
        _ inventoryEntry: WorkspaceInventoryEntry,
        coordinatedURL: URL,
        rootURL: URL
    ) throws -> CapturedEntry {
        guard WorkspaceFilePath.isContained(coordinatedURL, inside: rootURL) else {
            throw WorkspaceFileServiceError.outsideRoot
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let before = try coordinatedURL.resourceValues(forKeys: keys)
        guard before.isRegularFile == true else {
            throw WorkspaceFileServiceError.notRegularFile
        }
        guard let beforeSize = before.fileSize,
              beforeSize == inventoryEntry.byteCount else {
            throw WorkspaceFileServiceError.sourceChanged
        }
        guard beforeSize <= WorkspaceInventoryPolicy.maximumFileBytes else {
            throw WorkspaceFileServiceError.fileTooLarge
        }

        let handle = try FileHandle(forReadingFrom: coordinatedURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        var content = Data()
        content.reserveCapacity(beforeSize)
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            guard byteCount <= WorkspaceInventoryPolicy.maximumFileBytes else {
                throw WorkspaceFileServiceError.fileTooLarge
            }
            hasher.update(data: chunk)
            content.append(chunk)
        }

        let after = try coordinatedURL.resourceValues(forKeys: keys)
        guard
            after.isRegularFile == true,
            after.fileSize == before.fileSize,
            after.contentModificationDate == before.contentModificationDate,
            byteCount == beforeSize
        else {
            throw WorkspaceFileServiceError.sourceChanged
        }

        let modifiedAtNanoseconds = Int64(
            ((after.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000_000).rounded()
        )
        return CapturedEntry(
            snapshotEntry: WorkspaceSnapshotEntry(
                relativePath: inventoryEntry.relativePath,
                byteCount: byteCount,
                modifiedAtNanoseconds: modifiedAtNanoseconds,
                sha256: Data(hasher.finalize())
            ),
            content: content
        )
    }

    private static func manifestDigest(entries: [WorkspaceSnapshotEntry]) -> Data {
        var hasher = SHA256()
        for entry in entries {
            let path = Data(entry.relativePath.utf8)
            update(&hasher, integer: UInt64(path.count))
            hasher.update(data: path)
            update(&hasher, integer: UInt64(entry.byteCount))
            update(&hasher, integer: UInt64(bitPattern: entry.modifiedAtNanoseconds))
            hasher.update(data: entry.sha256)
        }
        return Data(hasher.finalize())
    }

    private static func update(_ hasher: inout SHA256, integer: UInt64) {
        var bigEndian = integer.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(data: Data(bytes))
        }
    }
}
