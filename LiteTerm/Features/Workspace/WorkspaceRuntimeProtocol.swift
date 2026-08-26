import Foundation
import LiteTermCore

public struct WorkspaceControllerServices: @unchecked Sendable {
    public var inspect: @Sendable (URL) async throws -> WorkspaceInspection
    public var capture: @Sendable (
        UInt64,
        URL,
        WorkspaceInventoryEvaluation
    ) async throws -> WorkspaceCapturedSnapshot
    public var snapshotIsCurrent: @Sendable (
        WorkspaceCapturedSnapshot,
        URL,
        WorkspaceKind
    ) async throws -> Bool
    public var validateWeb: @Sendable (
        WorkspaceCapturedSnapshot,
        WorkspaceProfile
    ) async -> WebWorkspaceValidationReport
    public var smokeWeb: @MainActor @Sendable (
        LoopbackServerLease,
        String,
        Duration
    ) async -> [WorkspaceProblem]
    public var inspectSwift: @Sendable (WorkspaceCapturedSnapshot) async -> SwiftWorkspaceAdvice
    public var checkPython: @Sendable (
        WorkspaceCapturedSnapshot,
        WorkspaceProfile
    ) async -> PythonCheckReport
    public var cancelPython: @Sendable () async -> Void
    public var startServer: @Sendable (
        UInt64,
        UUID,
        PreviewResponseSource
    ) async throws -> LoopbackServerLease
    public var stopServer: @Sendable () async -> Void
    public var serverIsRunning: @Sendable () async -> Bool
    public var verifyHealth: @Sendable (
        LoopbackServerLease,
        String
    ) async throws -> HealthProbeResult
    public var now: @Sendable () -> Date

    public init(
        inspect: @escaping @Sendable (URL) async throws -> WorkspaceInspection,
        capture: @escaping @Sendable (
            UInt64,
            URL,
            WorkspaceInventoryEvaluation
        ) async throws -> WorkspaceCapturedSnapshot,
        snapshotIsCurrent: @escaping @Sendable (
            WorkspaceCapturedSnapshot,
            URL,
            WorkspaceKind
        ) async throws -> Bool,
        validateWeb: @escaping @Sendable (
            WorkspaceCapturedSnapshot,
            WorkspaceProfile
        ) async -> WebWorkspaceValidationReport,
        smokeWeb: @escaping @MainActor @Sendable (
            LoopbackServerLease,
            String,
            Duration
        ) async -> [WorkspaceProblem],
        inspectSwift: @escaping @Sendable (WorkspaceCapturedSnapshot) async -> SwiftWorkspaceAdvice,
        checkPython: @escaping @Sendable (
            WorkspaceCapturedSnapshot,
            WorkspaceProfile
        ) async -> PythonCheckReport,
        cancelPython: @escaping @Sendable () async -> Void,
        startServer: @escaping @Sendable (
            UInt64,
            UUID,
            PreviewResponseSource
        ) async throws -> LoopbackServerLease,
        stopServer: @escaping @Sendable () async -> Void,
        serverIsRunning: @escaping @Sendable () async -> Bool,
        verifyHealth: @escaping @Sendable (
            LoopbackServerLease,
            String
        ) async throws -> HealthProbeResult,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.inspect = inspect
        self.capture = capture
        self.snapshotIsCurrent = snapshotIsCurrent
        self.validateWeb = validateWeb
        self.smokeWeb = smokeWeb
        self.inspectSwift = inspectSwift
        self.checkPython = checkPython
        self.cancelPython = cancelPython
        self.startServer = startServer
        self.stopServer = stopServer
        self.serverIsRunning = serverIsRunning
        self.verifyHealth = verifyHealth
        self.now = now
    }

    public static func live(
        inventory: WorkspaceInventoryService = WorkspaceInventoryService(),
        snapshots: WorkspaceSnapshotService = WorkspaceSnapshotService(),
        web: WebWorkspaceRunner = WebWorkspaceRunner(),
        swift: SwiftWorkspaceAdvisor = SwiftWorkspaceAdvisor(),
        python: PythonWorkspaceRunner = PythonWorkspaceRunner(),
        server: LoopbackPreviewServer = LoopbackPreviewServer(),
        health: HealthProbe = HealthProbe()
    ) -> WorkspaceControllerServices {
        WorkspaceControllerServices(
            inspect: { try await inventory.inspect(rootURL: $0) },
            capture: { generation, rootURL, evaluation in
                try await snapshots.captureBundle(
                    generation: generation,
                    rootURL: rootURL,
                    evaluation: evaluation
                )
            },
            snapshotIsCurrent: { expected, rootURL, expectedKind in
                let current = try await inventory.inspect(rootURL: rootURL)
                guard current.classification.kind == expectedKind else { return false }
                return try await snapshots.matchesCurrentFiles(
                    expected,
                    rootURL: rootURL,
                    evaluation: current.evaluation
                )
            },
            validateWeb: { snapshot, profile in
                WebWorkspaceRunner.validate(snapshot: snapshot, profile: profile)
            },
            smokeWeb: { lease, entrypoint, timeout in
                await web.smoke(lease: lease, entrypoint: entrypoint, timeout: timeout)
            },
            inspectSwift: { snapshot in swift.inspect(snapshot: snapshot) },
            checkPython: { snapshot, profile in
                await python.check(snapshot: snapshot, profile: profile)
            },
            cancelPython: { await python.cancel() },
            startServer: { generation, runtimeID, source in
                try await server.start(
                    generation: generation,
                    runtimeID: runtimeID,
                    source: source
                )
            },
            stopServer: { await server.stop() },
            serverIsRunning: { await server.isRunning },
            verifyHealth: { lease, relativePath in
                try await health.verify(lease: lease, relativePath: relativePath)
            }
        )
    }
}
