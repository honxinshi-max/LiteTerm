import Foundation
import LiteSpaceCore

public enum PythonRuntimeConfigurationError: Error, Equatable, Sendable {
    case invalidKind
    case missingEntrypoint
}

public struct PythonRuntimeConfiguration: Equatable, Sendable {
    public let generation: UInt64
    public let entrypoint: String
    public let testConvention: WorkspaceTestConvention
    public let allowedImports: [String]
    public let resourceBudget: RuntimeResourceBudget

    public init(
        snapshot: WorkspaceCapturedSnapshot,
        profile: WorkspaceProfile,
        resourceBudget: RuntimeResourceBudget = .iPadCandidate
    ) throws {
        guard profile.kind == .python else { throw PythonRuntimeConfigurationError.invalidKind }
        guard let entrypoint = profile.entrypoint,
              snapshot.content(relativePath: entrypoint) != nil else {
            throw PythonRuntimeConfigurationError.missingEntrypoint
        }
        generation = snapshot.snapshot.generation
        self.entrypoint = entrypoint
        testConvention = profile.testConvention
        allowedImports = [
            "__future__", "abc", "collections", "contextlib", "dataclasses",
            "datetime", "decimal", "enum", "functools", "hashlib", "html",
            "io", "itertools", "json", "math", "operator", "re", "statistics",
            "string", "sys", "time", "types", "typing", "unittest", "urllib",
            "wsgiref"
        ]
        self.resourceBudget = resourceBudget
    }
}
