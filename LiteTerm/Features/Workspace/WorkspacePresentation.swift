import Foundation
import LiteTermCore

public enum WorkspacePresentationState: String, Equatable, Sendable {
    case idle
    case inspecting
    case checking
    case checked
    case testing
    case starting
    case healthChecking
    case ready
    case completed
    case failed
    case stopping
}

public struct WorkspacePresentation: Equatable, Sendable {
    public let state: WorkspacePresentationState
    public let statusText: String
    public let kind: WorkspaceKind?
    public let runtimeLabel: String?
    public let problems: [WorkspaceProblem]
    public let publishedPort: Int?
    public let playgroundsHandoff: SwiftPlaygroundsHandoffIntent?
    public let acceptedFileCount: Int
    public let acceptedSourceBytes: Int
    public let testSummary: String?
    public let previewAvailable: Bool

    public static let idle = WorkspacePresentation(
        state: .idle,
        statusText: "Idle",
        kind: nil,
        runtimeLabel: nil,
        problems: [],
        publishedPort: nil,
        playgroundsHandoff: nil,
        acceptedFileCount: 0,
        acceptedSourceBytes: 0,
        testSummary: nil,
        previewAvailable: false
    )
}
