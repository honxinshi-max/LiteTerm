import Foundation

public struct DeletionConfirmationRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let targetURL: URL
    public let rootRelativePath: String
    public let fileIdentity: LocalFileIdentity

    public init(
        id: UUID = UUID(),
        targetURL: URL,
        rootRelativePath: String,
        fileIdentity: LocalFileIdentity
    ) {
        self.id = id
        self.targetURL = targetURL
        self.rootRelativePath = rootRelativePath
        self.fileIdentity = fileIdentity
    }
}

public struct ShellExecution: Equatable, Sendable {
    public let outputLines: [String]
    public let directoryChange: URL?
    public let editorURL: URL?
    public let clearRequested: Bool
    public let deletionConfirmationRequest: DeletionConfirmationRequest?

    public init(
        outputLines: [String] = [],
        directoryChange: URL? = nil,
        editorURL: URL? = nil,
        clearRequested: Bool = false,
        deletionConfirmationRequest: DeletionConfirmationRequest? = nil
    ) {
        self.outputLines = outputLines
        self.directoryChange = directoryChange
        self.editorURL = editorURL
        self.clearRequested = clearRequested
        self.deletionConfirmationRequest = deletionConfirmationRequest
    }
}

public actor LocalShell {
    private let rootURL: URL
    private let parser = ShellCommandParser()
    private let fileSystem: any LocalFileSystemAccess
    private var currentDirectoryURL: URL
    private var pendingDeletionRequest: DeletionConfirmationRequest?

    public init(
        rootURL: URL,
        fileSystem: (any LocalFileSystemAccess)? = nil
    ) {
        let bootstrapFileSystem: any LocalFileSystemAccess = fileSystem ?? LocalFileSystem(rootURL: rootURL)
        let bootstrapResolver = WorkspacePathResolver(
            rootURL: rootURL,
            currentDirectoryURL: rootURL,
            pathInspector: bootstrapFileSystem
        )
        let resolvedRoot = (try? bootstrapResolver.resolve("/")) ?? rootURL
        self.rootURL = resolvedRoot
        self.fileSystem = fileSystem ?? LocalFileSystem(rootURL: resolvedRoot)
        self.currentDirectoryURL = resolvedRoot
    }

    public func execute(_ input: String) async -> ShellExecution {
        pendingDeletionRequest = nil

        do {
            let command = try parser.parse(input)
            let resolver = WorkspacePathResolver(
                rootURL: rootURL,
                currentDirectoryURL: currentDirectoryURL,
                pathInspector: fileSystem
            )
            return try execute(command, resolver: resolver)
        } catch {
            return ShellExecution(outputLines: [message(for: error)])
        }
    }

    public func confirmDeletion(_ request: DeletionConfirmationRequest) async -> ShellExecution {
        guard pendingDeletionRequest == request else {
            return ShellExecution(outputLines: ["Error: deletion request expired"])
        }
        pendingDeletionRequest = nil
        do {
            try fileSystem.revalidateAndRemoveFile(
                rootURL: rootURL,
                rootRelativePath: request.rootRelativePath,
                expectedIdentity: request.fileIdentity
            )
            return ShellExecution()
        } catch {
            return ShellExecution(outputLines: [message(for: error)])
        }
    }

    public func cancelDeletion(_ request: DeletionConfirmationRequest) async {
        guard pendingDeletionRequest == request else { return }
        pendingDeletionRequest = nil
    }

    public func invalidatePendingDeletion() async {
        pendingDeletionRequest = nil
    }

    private func execute(_ command: ShellCommand, resolver: WorkspacePathResolver) throws -> ShellExecution {
        switch command {
        case .pwd:
            return ShellExecution(outputLines: [resolver.displayPath(for: currentDirectoryURL)])
        case let .ls(path):
            let target = try resolver.resolve(path ?? ".")
            return ShellExecution(outputLines: try fileSystem.list(at: target))
        case let .cd(path):
            let target = try resolver.resolve(path)
            guard try fileSystem.isDirectory(at: target) else {
                throw CocoaError(.fileNoSuchFile)
            }
            currentDirectoryURL = target
            return ShellExecution(directoryChange: target)
        case let .cat(path):
            let target = try resolver.resolve(path)
            let text = try fileSystem.readText(at: target)
            return ShellExecution(outputLines: text.isEmpty ? [] : text.components(separatedBy: "\n"))
        case let .mkdir(path):
            try fileSystem.createDirectory(at: resolver.resolve(path))
            return ShellExecution()
        case let .touch(path):
            try fileSystem.touch(at: resolver.resolve(path))
            return ShellExecution()
        case let .copy(source, destination):
            try fileSystem.copyItem(from: resolver.resolve(source), to: resolver.resolve(destination))
            return ShellExecution()
        case let .move(source, destination):
            try fileSystem.moveItem(from: resolver.resolve(source), to: resolver.resolve(destination))
            return ShellExecution()
        case let .remove(path):
            let target = try resolver.resolve(path)
            guard target.path != rootURL.path else {
                throw LocalFileSystemError.workspaceRootRemoval
            }
            guard try !fileSystem.isDirectory(at: target) else {
                throw LocalFileSystemError.directoryRemoval
            }
            let rootRelativePath = try resolver.rootRelativePath(for: target)
            guard !rootRelativePath.isEmpty else {
                throw LocalFileSystemError.workspaceRootRemoval
            }
            let request = DeletionConfirmationRequest(
                targetURL: target,
                rootRelativePath: rootRelativePath,
                fileIdentity: try fileSystem.deletionIdentity(at: target)
            )
            pendingDeletionRequest = request
            return ShellExecution(deletionConfirmationRequest: request)
        case .clear:
            return ShellExecution(clearRequested: true)
        case let .edit(path):
            let target = try resolver.resolve(path)
            try fileSystem.prepareForEditing(at: target)
            return ShellExecution(editorURL: target)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case LocalFileSystemError.fileTooLarge:
            return "Error: file exceeds the 5 MiB read/edit limit"
        case LocalFileSystemError.invalidText:
            return "Error: file is not valid UTF-8 text"
        case LocalFileSystemError.notRegularFile:
            return "Error: target is not a regular file"
        case LocalFileSystemError.deletionRequestExpired:
            return "Error: deletion request expired"
        case LocalFileSystemError.workspaceRootRemoval:
            return "Error: workspace root cannot be removed"
        case LocalFileSystemError.directoryRemoval:
            return "Error: directories cannot be removed"
        case WorkspacePathResolverError.outsideWorkspace:
            return "Error: path is outside the workspace"
        case WorkspacePathResolverError.unresolvablePath:
            return "Error: path cannot be resolved"
        case ShellCommandParserError.emptyCommand:
            return "Error: command is required"
        case ShellCommandParserError.unknownCommand:
            return "Error: unsupported command"
        case ShellCommandParserError.wrongArity:
            return "Error: wrong number of arguments"
        case ShellCommandParserError.unterminatedQuote, ShellCommandParserError.unterminatedEscape:
            return "Error: invalid quoted path"
        default:
            return "Error: operation failed"
        }
    }
}
