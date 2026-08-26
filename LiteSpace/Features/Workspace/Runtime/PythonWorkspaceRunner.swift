import Foundation
import LiteSpaceCore
import LiteSpacePythonBridge

public enum PythonRuntimeAvailability: Equatable, Sendable {
    case unavailable
    case available
}

public struct PythonCheckReport: Equatable, Sendable {
    public let generation: UInt64
    public let availability: PythonRuntimeAvailability
    public let checkedRelativePaths: [String]
    public let problems: [WorkspaceProblem]
    public let didCompile: Bool

    public var passed: Bool {
        availability == .available
            && didCompile
            && problems.allSatisfy { $0.severity != .error }
    }
}

public actor PythonWorkspaceRunner {
    private let runtimeAvailable: @Sendable () -> Bool

    public init(runtimeAvailable: @escaping @Sendable () -> Bool = LTIsPythonRuntimeAvailable) {
        self.runtimeAvailable = runtimeAvailable
    }

    public func check(
        snapshot: WorkspaceCapturedSnapshot,
        profile: WorkspaceProfile
    ) -> PythonCheckReport {
        let pythonPaths = snapshot.relativePaths
            .filter { $0.lowercased().hasSuffix(".py") }
            .sorted()
        guard (try? PythonRuntimeConfiguration(snapshot: snapshot, profile: profile)) != nil else {
            let problem = try? WorkspaceProblem(
                stage: .check,
                severity: .error,
                category: .configuration,
                message: "The Python entrypoint is missing from the current snapshot.",
                recoveryAction: "Choose a root-contained Python entrypoint and run Check again."
            )
            return PythonCheckReport(
                generation: snapshot.snapshot.generation,
                availability: .unavailable,
                checkedRelativePaths: [],
                problems: problem.map { [$0] } ?? [],
                didCompile: false
            )
        }

        guard runtimeAvailable() else {
            return PythonCheckReport(
                generation: snapshot.snapshot.generation,
                availability: .unavailable,
                checkedRelativePaths: pythonPaths,
                problems: PythonProblemMapper.unavailable().map { [$0] } ?? [],
                didCompile: false
            )
        }

        // The artifact-backed path is deliberately held closed until the C bridge's
        // initialize/compile/cancel lifecycle suite passes on an iPad simulator.
        return PythonCheckReport(
            generation: snapshot.snapshot.generation,
            availability: .unavailable,
            checkedRelativePaths: pythonPaths,
            problems: PythonProblemMapper.unavailable().map { [$0] } ?? [],
            didCompile: false
        )
    }

    public func cancel() {
        // No runtime handle can exist while the reviewed capability is unavailable.
    }
}
