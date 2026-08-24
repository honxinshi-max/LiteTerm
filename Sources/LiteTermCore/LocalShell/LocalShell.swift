import Foundation

public struct DeletionConfirmationRequest: Equatable, Sendable {
    public let targetURL: URL

    public init(targetURL: URL) {
        self.targetURL = targetURL
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
    private var history: TerminalHistory

    public init(
        rootURL: URL,
        historyLimit: Int = 2_000,
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
        self.history = TerminalHistory(limit: historyLimit)
    }

    public func execute(_ input: String) async -> ShellExecution {
        history.append(input)

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
            try fileSystem.removeFile(at: resolver.resolve(path))
            return ShellExecution()
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
