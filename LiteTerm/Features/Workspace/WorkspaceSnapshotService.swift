import CryptoKit
import Foundation
import LiteTermCore

public actor WorkspaceSnapshotService {
    public init() {}

    public func capture(
        generation: UInt64,
        rootURL: URL,
        evaluation: WorkspaceInventoryEvaluation
    ) throws -> WorkspaceSnapshot {
        guard evaluation.violations.isEmpty else {
            throw WorkspaceFileServiceError.inventoryRejected
        }

        var capturedEntries: [WorkspaceSnapshotEntry] = []
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

        let canonicalEntries = capturedEntries.sorted { $0.relativePath < $1.relativePath }
        return try WorkspaceSnapshot(
            generation: generation,
            entries: canonicalEntries,
            manifestSHA256: Self.manifestDigest(entries: canonicalEntries)
        )
    }

    private static func captureEntry(
        _ inventoryEntry: WorkspaceInventoryEntry,
        coordinatedURL: URL,
        rootURL: URL
    ) throws -> WorkspaceSnapshotEntry {
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
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            guard byteCount <= WorkspaceInventoryPolicy.maximumFileBytes else {
                throw WorkspaceFileServiceError.fileTooLarge
            }
            hasher.update(data: chunk)
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
        return WorkspaceSnapshotEntry(
            relativePath: inventoryEntry.relativePath,
            byteCount: byteCount,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            sha256: Data(hasher.finalize())
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
