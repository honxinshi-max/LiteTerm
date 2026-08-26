import Foundation
import LiteSpaceCore

public enum SwiftPlaygroundsHandoffKind: Equatable, Sendable {
    case shareToSwiftPlaygrounds
}

public struct SwiftPlaygroundsHandoffIntent: Equatable, Sendable {
    public let kind: SwiftPlaygroundsHandoffKind
    public let generation: UInt64

    public init(kind: SwiftPlaygroundsHandoffKind, generation: UInt64) {
        self.kind = kind
        self.generation = generation
    }
}

public struct SwiftWorkspaceAdvice: Equatable, Sendable {
    public let label: String
    public let canRunLocally: Bool
    public let problems: [WorkspaceProblem]
    public let handoff: SwiftPlaygroundsHandoffIntent
}

public struct SwiftWorkspaceAdvisor: Sendable {
    public init() {}

    public func inspect(snapshot: WorkspaceCapturedSnapshot) -> SwiftWorkspaceAdvice {
        let swiftPaths = snapshot.relativePaths.filter { $0.lowercased().hasSuffix(".swift") }
        var problems = swiftPaths.flatMap { relativePath in
            SwiftSourceDiagnostics.inspect(
                data: snapshot.content(relativePath: relativePath) ?? Data(),
                relativePath: relativePath
            )
        }
        if swiftPaths.isEmpty,
           let problem = try? WorkspaceProblem(
            stage: .check,
            severity: .error,
            category: .configuration,
            message: "No Swift source file is present in the accepted snapshot.",
            recoveryAction: "Add a Swift source file and run Check again."
           ) {
            problems.append(problem)
        }

        return SwiftWorkspaceAdvice(
            label: "Lightweight diagnostics",
            canRunLocally: false,
            problems: Array(problems.prefix(SwiftSourceDiagnostics.maximumProblems)),
            handoff: SwiftPlaygroundsHandoffIntent(
                kind: .shareToSwiftPlaygrounds,
                generation: snapshot.snapshot.generation
            )
        )
    }
}
