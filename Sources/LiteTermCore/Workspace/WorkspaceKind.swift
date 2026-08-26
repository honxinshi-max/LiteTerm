public enum WorkspaceKind: String, Codable, CaseIterable, Sendable {
    case web
    case python
    case swift
    case nodeRequired
    case unsupported
    case ambiguous
}

public enum WorkspaceIndicator: String, Hashable, Sendable {
    case packageSwift
    case swiftSource
    case pyproject
    case requirements
    case pythonSource
    case indexHTML
    case packageJSON
}

public struct WorkspaceClassification: Equatable, Sendable {
    public let kind: WorkspaceKind
    public let candidates: Set<WorkspaceKind>
    public let indicators: Set<WorkspaceIndicator>

    public init(
        kind: WorkspaceKind,
        candidates: Set<WorkspaceKind>,
        indicators: Set<WorkspaceIndicator>
    ) {
        self.kind = kind
        self.candidates = candidates
        self.indicators = indicators
    }
}
