import Foundation
import LiteTermCore

public enum WorkspaceFileServiceError: Error, Equatable, Sendable {
    case rootIsNotDirectory
    case coordinationFailed
    case enumerationFailed
    case outsideRoot
    case sourceChanged
    case fileTooLarge
    case notRegularFile
    case inventoryRejected
    case invalidRootIdentity
}

public struct WorkspaceInspection: Equatable, Sendable {
    public let evaluation: WorkspaceInventoryEvaluation
    public let classification: WorkspaceClassification

    public init(
        evaluation: WorkspaceInventoryEvaluation,
        classification: WorkspaceClassification
    ) {
        self.evaluation = evaluation
        self.classification = classification
    }
}

public actor WorkspaceInventoryService {
    private let policy: WorkspaceInventoryPolicy
    private let classifier: WorkspaceClassifier

    public init(
        policy: WorkspaceInventoryPolicy = WorkspaceInventoryPolicy(),
        classifier: WorkspaceClassifier = WorkspaceClassifier()
    ) {
        self.policy = policy
        self.classifier = classifier
    }

    public func inspect(rootURL: URL) throws -> WorkspaceInspection {
        let entries = try WorkspaceCoordinatedRead.perform(at: rootURL) { coordinatedRoot in
            try Self.enumerate(rootURL: coordinatedRoot)
        }
        let evaluation = policy.evaluate(entries)
        let classification = classifier.classify(
            relativePaths: evaluation.acceptedFiles.map(\.relativePath)
        )
        return WorkspaceInspection(evaluation: evaluation, classification: classification)
    }

    private static func enumerate(rootURL: URL) throws -> [WorkspaceInventoryEntry] {
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw WorkspaceFileServiceError.rootIsNotDirectory
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw WorkspaceFileServiceError.enumerationFailed
        }

        var entries: [WorkspaceInventoryEntry] = []
        while let item = enumerator.nextObject() as? URL {
            let relativePath = try WorkspaceFilePath.relativePath(of: item, inside: root)
            let values = try item.resourceValues(forKeys: Set(keys))
            let isSymbolicLink = values.isSymbolicLink == true
            let resolvedURL = isSymbolicLink ? item.resolvingSymlinksInPath() : item
            let targetIsContained = WorkspaceFilePath.isContained(resolvedURL, inside: root)
            let targetValues = isSymbolicLink && targetIsContained
                ? try resolvedURL.resourceValues(forKeys: Set(keys))
                : values

            if targetValues.isDirectory == true && shouldSkipDescendants(relativePath: relativePath) {
                enumerator.skipDescendants()
            }

            entries.append(WorkspaceInventoryEntry(
                relativePath: relativePath,
                byteCount: targetValues.fileSize ?? 0,
                isDirectory: targetValues.isDirectory == true,
                isRegularFile: targetValues.isRegularFile == true,
                isSymbolicLink: isSymbolicLink,
                symbolicLinkTargetIsInsideRoot: targetIsContained
            ))
            if entries.count > WorkspaceInventoryPolicy.maximumEntryCount {
                break
            }
        }

        if enumerationFailed {
            throw WorkspaceFileServiceError.enumerationFailed
        }
        return entries
    }

    private static func shouldSkipDescendants(relativePath: String) -> Bool {
        guard let name = relativePath.split(separator: "/").last else { return false }
        let lowercaseName = name.lowercased()
        return lowercaseName.hasPrefix(".") || [
            "node_modules", "__pycache__", "build", "dist", "deriveddata",
            "venv", "vendor", "pods", "packages"
        ].contains(lowercaseName)
    }
}

enum WorkspaceCoordinatedRead {
    static func perform<Value>(
        at requestedURL: URL,
        accessor: (URL) throws -> Value
    ) throws -> Value {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let box = WorkspaceCoordinationResultBox<Value>()
        coordinator.coordinate(readingItemAt: requestedURL, options: [], error: &coordinationError) {
            coordinatedURL in
            box.result = Result { try accessor(coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result = box.result else {
            throw WorkspaceFileServiceError.coordinationFailed
        }
        return try result.get()
    }
}

enum WorkspaceFilePath {
    static func relativePath(of item: URL, inside root: URL) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let itemComponents = item.standardizedFileURL.pathComponents
        guard
            itemComponents.count > rootComponents.count,
            zip(rootComponents, itemComponents).allSatisfy(==)
        else {
            throw WorkspaceFileServiceError.outsideRoot
        }
        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func isContained(_ item: URL, inside root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let resolvedItem = item.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard resolvedItem.count >= resolvedRoot.count else { return false }
        return zip(resolvedRoot, resolvedItem).allSatisfy(==)
    }
}

private final class WorkspaceCoordinationResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}
