import Foundation

public enum WorkspaceTestConvention: Codable, Equatable, Sendable {
    case none
    case webSmoke(relativePaths: [String])
    case pythonUnittest(startDirectory: String, pattern: String)
}

public enum WorkspaceProfileError: Error, Equatable, Sendable {
    case unsupportedKind
    case invalidEntrypoint
    case invalidTestConvention
    case invalidHealthPath
}

public struct WorkspaceProfile: Codable, Equatable, Sendable {
    public let kind: WorkspaceKind
    public let entrypoint: String?
    public let testConvention: WorkspaceTestConvention
    public let healthPath: String

    public init(
        kind: WorkspaceKind,
        entrypoint: String?,
        testConvention: WorkspaceTestConvention,
        healthPath: String
    ) throws {
        guard [.web, .python, .swift].contains(kind) else {
            throw WorkspaceProfileError.unsupportedKind
        }
        if let entrypoint, !WorkspaceRelativePathPolicy.isValidFilePath(entrypoint) {
            throw WorkspaceProfileError.invalidEntrypoint
        }
        guard Self.isValid(testConvention: testConvention) else {
            throw WorkspaceProfileError.invalidTestConvention
        }
        guard WorkspaceRelativePathPolicy.isValidHealthPath(healthPath) else {
            throw WorkspaceProfileError.invalidHealthPath
        }

        self.kind = kind
        self.entrypoint = entrypoint
        self.testConvention = testConvention
        self.healthPath = healthPath
    }

    private enum CodingKeys: String, CodingKey {
        case kind, entrypoint, testConvention, healthPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(WorkspaceKind.self, forKey: .kind),
            entrypoint: container.decodeIfPresent(String.self, forKey: .entrypoint),
            testConvention: container.decode(WorkspaceTestConvention.self, forKey: .testConvention),
            healthPath: container.decode(String.self, forKey: .healthPath)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encode(testConvention, forKey: .testConvention)
        try container.encode(healthPath, forKey: .healthPath)
    }

    private static func isValid(testConvention: WorkspaceTestConvention) -> Bool {
        switch testConvention {
        case .none:
            return true
        case let .webSmoke(relativePaths):
            return relativePaths.allSatisfy(WorkspaceRelativePathPolicy.isValidFilePath)
        case let .pythonUnittest(startDirectory, pattern):
            return WorkspaceRelativePathPolicy.isValidFilePath(startDirectory)
                && !pattern.isEmpty
                && !pattern.contains("/")
                && !pattern.contains("\\")
                && !pattern.contains("..")
        }
    }
}
