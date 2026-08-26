import Combine
import Foundation
import LiteTermCore

public enum WorkspaceControllerAction: Equatable, Sendable {
    case check
    case test
    case run
}

@MainActor
public final class WorkspaceController: ObservableObject {
    @Published public private(set) var presentation: WorkspacePresentation = .idle

    public var onTerminalSummary: (([String]) -> Void)?

    private var rootURL: URL
    private let services: WorkspaceControllerServices
    private var gate = WorkspaceGateReducer()
    private var operationID = UUID()
    private var runTask: Task<Void, Never>?
    private var currentLease: LoopbackServerLease?
    private var previewBootstrapURL: URL?
    private var kind: WorkspaceKind?
    private var runtimeLabel: String?
    private var problems: [WorkspaceProblem] = []
    private var playgroundsHandoff: SwiftPlaygroundsHandoffIntent?
    private var acceptedFileCount = 0
    private var acceptedSourceBytes = 0
    private var testSummary: String?
    private var terminalRequestedAction: WorkspaceShellAction?

    public init(
        rootURL: URL,
        services: WorkspaceControllerServices = .live()
    ) {
        self.rootURL = rootURL
        self.services = services
    }

    public func perform(_ action: WorkspaceControllerAction) {
        let previousTask = runTask
        previousTask?.cancel()
        operationID = UUID()
        let requestedOperationID = operationID
        runTask = Task { @MainActor [weak self] in
            _ = await previousTask?.result
            guard let self, self.operationID == requestedOperationID else { return }
            await self.withdrawRuntimeAndReset(publish: true)
            guard !Task.isCancelled, self.operationID == requestedOperationID else { return }
            await self.execute(action, operationID: requestedOperationID)
            if self.operationID == requestedOperationID,
               !self.isReadyState {
                self.runTask = nil
            }
        }
    }

    public func handleShellAction(_ action: WorkspaceShellAction) {
        switch action {
        case .showStatus:
            onTerminalSummary?([terminalStatusLine])
        case .check:
            terminalRequestedAction = action
            perform(.check)
        case .test:
            terminalRequestedAction = action
            perform(.test)
        case .run:
            terminalRequestedAction = action
            perform(.run)
        case .stop:
            terminalRequestedAction = action
            Task { @MainActor [weak self] in await self?.stopAndInvalidate() }
        case .showProblems:
            onTerminalSummary?(terminalProblemLines)
        case .showPorts:
            if let port = presentation.publishedPort {
                onTerminalSummary?(["Verified local service port: \(port)"])
            } else {
                onTerminalSummary?(["No verified service port"])
            }
        }
    }

    public func installRoot(_ newRootURL: URL) async {
        await stopAndInvalidate()
        rootURL = newRootURL
    }

    public func sourceDidChange() async {
        await stopAndInvalidate()
    }

    public func stopAndInvalidate() async {
        operationID = UUID()
        let task = runTask
        runTask = nil
        task?.cancel()
        _ = await task?.result
        _ = gate.invalidate()
        currentLease = nil
        previewBootstrapURL = nil
        await services.stopServer()
        publish(statusOverride: "Idle")
        finishTerminalRequestIfNeeded()
    }

    func authenticatedPreviewURL() -> URL? {
        guard presentation.publishedPort != nil else { return nil }
        return previewBootstrapURL
    }

    private func execute(_ action: WorkspaceControllerAction, operationID: UUID) async {
        problems = []
        playgroundsHandoff = nil
        runtimeLabel = nil
        testSummary = nil
        acceptedFileCount = 0
        acceptedSourceBytes = 0
        kind = nil
        let generation = gate.begin()
        publish()

        do {
            let inspection = try await services.inspect(rootURL)
            try Task.checkCancellation()
            guard isCurrent(operationID, generation: generation) else { return }
            acceptedFileCount = inspection.evaluation.acceptedFiles.count
            acceptedSourceBytes = inspection.evaluation.acceptedFiles.reduce(0) { $0 + $1.byteCount }
            kind = inspection.classification.kind

            guard inspection.evaluation.violations.isEmpty else {
                await fail(
                    generation: generation,
                    operationID: operationID,
                    failure: .resource,
                    problemCategory: .resource,
                    message: "The workspace exceeds a reviewed file or memory limit."
                )
                return
            }
            guard [.web, .swift, .python].contains(inspection.classification.kind) else {
                await fail(
                    generation: generation,
                    operationID: operationID,
                    failure: .unsupported,
                    problemCategory: .unsupported,
                    message: "This workspace type is unsupported or ambiguous."
                )
                return
            }
            _ = gate.reduce(.inspectionPassed, generation: generation, now: services.now())
            publish()

            let snapshot = try await services.capture(
                generation,
                rootURL,
                inspection.evaluation
            )
            try Task.checkCancellation()
            guard isCurrent(operationID, generation: generation) else { return }

            switch inspection.classification.kind {
            case .web:
                await executeWeb(
                    action,
                    snapshot: snapshot,
                    generation: generation,
                    operationID: operationID
                )
            case .swift:
                await executeSwift(
                    snapshot: snapshot,
                    generation: generation,
                    operationID: operationID
                )
            case .python:
                await executePython(
                    action,
                    snapshot: snapshot,
                    generation: generation,
                    operationID: operationID
                )
            case .nodeRequired, .unsupported, .ambiguous:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: .inspect,
                problemCategory: .fileAccess,
                message: "The workspace could not be inspected safely."
            )
        }
    }

    private func executeSwift(
        snapshot: WorkspaceCapturedSnapshot,
        generation: UInt64,
        operationID: UUID
    ) async {
        let advice = await services.inspectSwift(snapshot)
        guard isCurrent(operationID, generation: generation), !Task.isCancelled else { return }
        runtimeLabel = advice.label
        playgroundsHandoff = advice.handoff
        problems = advice.problems
        if advice.problems.contains(where: { $0.severity == .error }) {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: .check,
                existingProblems: advice.problems
            )
            return
        }
        _ = gate.reduce(.checkOnlyCompleted, generation: generation, now: services.now())
        publish(statusOverride: "Lightweight diagnostics passed")
        finishTerminalRequestIfNeeded()
    }

    private func executePython(
        _ action: WorkspaceControllerAction,
        snapshot: WorkspaceCapturedSnapshot,
        generation: UInt64,
        operationID: UUID
    ) async {
        runtimeLabel = "Embedded Python"
        let entrypoint = snapshot.relativePaths.first(where: { $0 == "main.py" })
            ?? snapshot.relativePaths.first(where: { $0.lowercased().hasSuffix(".py") })
        let profile: WorkspaceProfile
        do {
            profile = try WorkspaceProfile(
                kind: .python,
                entrypoint: entrypoint,
                testConvention: snapshot.relativePaths.contains(where: { $0.hasPrefix("tests/") })
                    ? .pythonUnittest(startDirectory: "tests", pattern: "test*.py")
                    : .none,
                healthPath: ""
            )
        } catch {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: .check,
                problemCategory: .configuration,
                message: "The Python workspace profile is invalid."
            )
            return
        }

        let report = await services.checkPython(snapshot, profile)
        guard isCurrent(operationID, generation: generation), !Task.isCancelled else { return }
        problems = report.problems
        guard report.passed else {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: report.availability == .unavailable ? .unsupported : .check,
                existingProblems: report.problems
            )
            return
        }

        // This branch remains unreachable until the artifact-backed runner is enabled.
        _ = gate.reduce(.checkOnlyCompleted, generation: generation, now: services.now())
        publish(statusOverride: action == .check ? "Python checks passed" : "Python runtime gated")
        finishTerminalRequestIfNeeded()
    }

    private func executeWeb(
        _ action: WorkspaceControllerAction,
        snapshot: WorkspaceCapturedSnapshot,
        generation: UInt64,
        operationID: UUID
    ) async {
        let profile: WorkspaceProfile
        do {
            let testPaths = snapshot.relativePaths.filter {
                ["test.html", "tests.html"].contains($0.lowercased())
            }
            profile = try WorkspaceProfile(
                kind: .web,
                entrypoint: "index.html",
                testConvention: .webSmoke(relativePaths: testPaths),
                healthPath: ""
            )
        } catch {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: .check,
                problemCategory: .configuration,
                message: "The Web workspace profile is invalid."
            )
            return
        }

        runtimeLabel = "Local Web"
        let validation = await services.validateWeb(snapshot, profile)
        guard isCurrent(operationID, generation: generation), !Task.isCancelled else { return }
        problems = validation.problems
        guard validation.passed, let source = validation.source else {
            await fail(
                generation: generation,
                operationID: operationID,
                failure: .check,
                existingProblems: validation.problems
            )
            return
        }
        if action == .check {
            _ = gate.reduce(.checkOnlyCompleted, generation: generation, now: services.now())
            publish(statusOverride: "Web checks passed")
            finishTerminalRequestIfNeeded()
            return
        }

        _ = gate.reduce(.checkPassed, generation: generation, now: services.now())
        publish()
        let probeRuntimeID = UUID()
        do {
            let probeLease = try await services.startServer(generation, probeRuntimeID, source)
            guard isCurrent(operationID, generation: generation), !Task.isCancelled else {
                await services.stopServer()
                return
            }
            var smokePaths = [validation.entrypoint]
            if case let .webSmoke(relativePaths) = profile.testConvention {
                smokePaths.append(contentsOf: relativePaths)
            }
            var smokeProblems: [WorkspaceProblem] = []
            for path in Array(Set(smokePaths)).sorted() {
                smokeProblems.append(contentsOf: await services.smokeWeb(
                    probeLease,
                    path,
                    .seconds(5)
                ))
                try Task.checkCancellation()
                guard isCurrent(operationID, generation: generation) else {
                    await services.stopServer()
                    return
                }
            }
            await services.stopServer()
            guard smokeProblems.isEmpty else {
                problems = smokeProblems
                await fail(
                    generation: generation,
                    operationID: operationID,
                    failure: .test,
                    existingProblems: smokeProblems
                )
                return
            }
            testSummary = profileHasProjectTests(profile)
                ? "Configured Web tests and built-in smoke passed"
                : "No project tests; built-in smoke only"
            if action == .test {
                _ = gate.reduce(.testOnlyCompleted, generation: generation, now: services.now())
                publish(statusOverride: "Web smoke passed")
                finishTerminalRequestIfNeeded()
                return
            }

            _ = gate.reduce(.testsPassed, generation: generation, now: services.now())
            publish()
            let runtimeID = UUID()
            let lease = try await services.startServer(generation, runtimeID, source)
            guard isCurrent(operationID, generation: generation), !Task.isCancelled else {
                await services.stopServer()
                return
            }
            currentLease = lease
            _ = gate.reduce(
                .serviceStarted(
                    port: lease.port,
                    listenerID: lease.listenerID,
                    runtimeID: lease.runtimeID,
                    secretHandle: lease.secretHandle
                ),
                generation: generation,
                now: services.now()
            )
            publish()

            let initialHealth = try await services.verifyHealth(lease, profile.healthPath)
            guard isCurrent(operationID, generation: generation), !Task.isCancelled,
                  initialHealth.generation == generation else {
                await services.stopServer()
                return
            }
            for _ in 0..<initialHealth.consecutiveSuccesses {
                _ = gate.reduce(
                    .healthSucceeded(expiresAt: initialHealth.healthExpiresAt),
                    generation: generation,
                    now: services.now()
                )
            }
            guard gate.publishedPort(at: services.now()) != nil else {
                await fail(
                    generation: generation,
                    operationID: operationID,
                    failure: .health,
                    problemCategory: .health,
                    message: "The service did not reach verified readiness."
                )
                return
            }
            previewBootstrapURL = try lease.authenticatedBootstrapURL(
                relativePath: validation.entrypoint
            )
            publish(statusOverride: "Ready")
            finishTerminalRequestIfNeeded()
            await monitorHealth(
                lease: lease,
                healthPath: profile.healthPath,
                generation: generation,
                operationID: operationID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(operationID, generation: generation), !Task.isCancelled else { return }
            await fail(
                generation: generation,
                operationID: operationID,
                failure: gateFailureForCurrentState,
                problemCategory: problemCategoryForCurrentState,
                message: "The local Web runtime did not complete its current gate."
            )
        }
    }

    private func monitorHealth(
        lease: LoopbackServerLease,
        healthPath: String,
        generation: UInt64,
        operationID: UUID
    ) async {
        while isCurrent(operationID, generation: generation), !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                let result = try await services.verifyHealth(lease, healthPath)
                guard result.generation == generation,
                      isCurrent(operationID, generation: generation),
                      await services.serverIsRunning() else {
                    throw PreviewRuntimeError.unavailable
                }
                _ = gate.reduce(
                    .healthSucceeded(expiresAt: result.healthExpiresAt),
                    generation: generation,
                    now: services.now()
                )
                publish(statusOverride: "Ready")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(operationID, generation: generation) else { return }
                currentLease = nil
                previewBootstrapURL = nil
                _ = gate.reduce(
                    .healthFailed(.health),
                    generation: generation,
                    now: services.now()
                )
                await services.stopServer()
                problems = Self.genericProblem(
                    category: .health,
                    stage: .health,
                    message: "The verified service stopped responding."
                ).map { [$0] } ?? []
                publish()
                finishTerminalRequestIfNeeded()
                return
            }
        }
    }

    private func fail(
        generation: UInt64,
        operationID: UUID,
        failure: WorkspaceFailureCategory,
        problemCategory: WorkspaceProblemCategory? = nil,
        message: String? = nil,
        existingProblems: [WorkspaceProblem] = []
    ) async {
        guard isCurrent(operationID, generation: generation) else { return }
        currentLease = nil
        previewBootstrapURL = nil
        _ = gate.reduce(.failed(failure), generation: generation, now: services.now())
        await services.stopServer()
        if !existingProblems.isEmpty {
            problems = Array(existingProblems.prefix(100))
        } else if let problemCategory, let message {
            problems = Self.genericProblem(
                category: problemCategory,
                stage: stage(for: failure),
                message: message
            ).map { [$0] } ?? []
        }
        publish()
        finishTerminalRequestIfNeeded()
    }

    private func withdrawRuntimeAndReset(publish shouldPublish: Bool) async {
        _ = gate.invalidate()
        currentLease = nil
        previewBootstrapURL = nil
        await services.cancelPython()
        await services.stopServer()
        if shouldPublish { publish(statusOverride: "Idle") }
    }

    private func isCurrent(_ requestedOperationID: UUID, generation: UInt64) -> Bool {
        operationID == requestedOperationID && gate.generation == generation
    }

    private var isReadyState: Bool {
        if case .ready = gate.state { return true }
        return false
    }

    private var gateFailureForCurrentState: WorkspaceFailureCategory {
        switch gate.state {
        case .testing: return .test
        case .starting: return .start
        case .healthChecking, .ready: return .health
        default: return .runtime
        }
    }

    private var problemCategoryForCurrentState: WorkspaceProblemCategory {
        switch gate.state {
        case .testing: return .testFailure
        case .starting, .ready: return .runtime
        case .healthChecking: return .health
        default: return .runtime
        }
    }

    private func publish(statusOverride: String? = nil) {
        let state = presentationState(for: gate.state)
        let port = gate.publishedPort(at: services.now())
        presentation = WorkspacePresentation(
            state: state,
            statusText: statusOverride ?? statusText(for: gate.state),
            kind: kind,
            runtimeLabel: runtimeLabel,
            problems: problems,
            publishedPort: port,
            playgroundsHandoff: playgroundsHandoff,
            acceptedFileCount: acceptedFileCount,
            acceptedSourceBytes: acceptedSourceBytes,
            testSummary: testSummary,
            previewAvailable: port != nil && previewBootstrapURL != nil
        )
    }

    private func presentationState(for state: WorkspaceGateState) -> WorkspacePresentationState {
        switch state {
        case .idle: return .idle
        case .inspecting: return .inspecting
        case .checking: return .checking
        case .checked: return .checked
        case .testing: return .testing
        case .starting: return .starting
        case .completed: return .completed
        case .healthChecking: return .healthChecking
        case .ready: return .ready
        case .failed: return .failed
        case .stopping: return .stopping
        }
    }

    private func statusText(for state: WorkspaceGateState) -> String {
        switch state {
        case .idle: return "Idle"
        case .inspecting: return "Inspecting"
        case .checking: return "Checking"
        case .checked: return "Checked"
        case .testing: return "Testing"
        case .starting: return "Starting"
        case .completed: return "Completed"
        case let .healthChecking(successes): return "Health check \(successes)/3"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .stopping: return "Stopping"
        }
    }

    private var terminalStatusLine: String {
        if let port = presentation.publishedPort {
            return "Workspace \(presentation.statusText); verified port \(port)"
        }
        return "Workspace \(presentation.statusText); no verified service port"
    }

    private var terminalProblemLines: [String] {
        guard !presentation.problems.isEmpty else { return ["No workspace problems"] }
        let grouped = Dictionary(grouping: presentation.problems, by: \.category)
        return grouped.keys.sorted { $0.rawValue < $1.rawValue }.map { category in
            "\(category.rawValue): \(grouped[category]?.count ?? 0)"
        }
    }

    private func finishTerminalRequestIfNeeded() {
        guard terminalRequestedAction != nil else { return }
        terminalRequestedAction = nil
        onTerminalSummary?([terminalStatusLine])
    }

    private func profileHasProjectTests(_ profile: WorkspaceProfile) -> Bool {
        if case let .webSmoke(relativePaths) = profile.testConvention {
            return !relativePaths.isEmpty
        }
        return false
    }

    private func stage(for failure: WorkspaceFailureCategory) -> WorkspaceStage {
        switch failure {
        case .inspect: return .inspect
        case .check: return .check
        case .test: return .test
        case .start: return .start
        case .health: return .health
        case .runtime: return .runtime
        case .resource: return .resource
        case .privacy: return .privacy
        case .unsupported: return .unsupported
        case .cancelled: return .runtime
        }
    }

    private static func genericProblem(
        category: WorkspaceProblemCategory,
        stage: WorkspaceStage,
        message: String
    ) -> WorkspaceProblem? {
        try? WorkspaceProblem(
            stage: stage,
            severity: .error,
            category: category,
            message: message,
            recoveryAction: "Review Problems, correct the workspace, and try again."
        )
    }
}
