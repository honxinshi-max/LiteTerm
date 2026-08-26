import Foundation

public enum WorkspaceStage: String, Codable, CaseIterable, Sendable {
    case inspect
    case check
    case test
    case start
    case health
    case runtime
    case resource
    case privacy
    case unsupported
}

public enum WorkspaceProblemSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case error
}

public enum WorkspaceProblemCategory: String, Codable, CaseIterable, Sendable {
    case configuration
    case fileAccess
    case syntax
    case testFailure
    case runtime
    case health
    case resource
    case privacy
    case unsupported
    case staleGeneration
}

public enum WorkspaceProblemError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidLocation
}

public struct WorkspaceProblemProjection: Codable, Equatable, Sendable {
    public let stage: WorkspaceStage
    public let severity: WorkspaceProblemSeverity
    public let category: WorkspaceProblemCategory

    public init(
        stage: WorkspaceStage,
        severity: WorkspaceProblemSeverity,
        category: WorkspaceProblemCategory
    ) {
        self.stage = stage
        self.severity = severity
        self.category = category
    }
}

public struct WorkspaceProblem: Equatable, Identifiable, Sendable {
    public static let maximumMessageBytes = 512
    public static let maximumRecoveryActionBytes = 256

    public let id: UUID
    public let stage: WorkspaceStage
    public let severity: WorkspaceProblemSeverity
    public let category: WorkspaceProblemCategory
    public let relativePath: String?
    public let line: Int?
    public let column: Int?
    public let message: String
    public let recoveryAction: String?

    public init(
        id: UUID = UUID(),
        stage: WorkspaceStage,
        severity: WorkspaceProblemSeverity,
        category: WorkspaceProblemCategory,
        relativePath: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String,
        recoveryAction: String? = nil
    ) throws {
        if let relativePath, !WorkspaceRelativePathPolicy.isValidFilePath(relativePath) {
            throw WorkspaceProblemError.invalidRelativePath
        }
        if let line, line < 1 {
            throw WorkspaceProblemError.invalidLocation
        }
        if let column, column < 1 {
            throw WorkspaceProblemError.invalidLocation
        }

        self.id = id
        self.stage = stage
        self.severity = severity
        self.category = category
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.message = Self.bounded(message, byteLimit: Self.maximumMessageBytes)
        self.recoveryAction = recoveryAction.map {
            Self.bounded($0, byteLimit: Self.maximumRecoveryActionBytes)
        }
    }

    public var persistenceProjection: WorkspaceProblemProjection {
        WorkspaceProblemProjection(stage: stage, severity: severity, category: category)
    }

    private static func bounded(_ value: String, byteLimit: Int) -> String {
        guard value.utf8.count > byteLimit else { return value }
        var bytes = Array(value.utf8.prefix(byteLimit))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) {
                return result
            }
            bytes.removeLast()
        }
        return ""
    }
}
