import Crypto
import LiteTermCore
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import SwiftUI
import XCTest
@testable import LiteTerm

@MainActor
final class SSHSessionBoundaryTests: XCTestCase {
    func testAppHostedLocalSSHReplacementAndLocalReturnKeepOneLiveTransport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-App-Acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let host = try makeHost()
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)
        let terminal = TerminalSessionCoordinator(rootURL: root)
        let clients = BoundaryClientStore()
        clients.delayFirstClose = true
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient
        )
        terminal.onRemoteInput = { [weak controller] bytes in
            controller?.send(bytes)
        }

        controller.scenePhaseChanged(.active)
        terminal.setMode(.ssh)
        controller.connect(host: host)
        let first = try XCTUnwrap(clients.clients.first)
        first.validateSavedHostKey()
        first.becomeReady()
        await drainMainActor()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(clients.activeClientCount, 1)

        terminal.sendText("remote-one\r")
        XCTAssertEqual(first.sentBytes, [Array("remote-one\r".utf8)])
        XCTAssertTrue(terminal.receiveRemoteBytes(Array("remote-output".utf8)))

        controller.connect(host: host)
        XCTAssertEqual(clients.clients.count, 1)
        XCTAssertEqual(clients.activeClientCount, 1)
        first.becomeReady()
        let staleAcknowledged = NIOLockedValueBox(false)
        first.deliver(Array("stale-output".utf8), acknowledged: staleAcknowledged)
        await drainMainActor()
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertTrue(staleAcknowledged.withLockedValue { $0 })

        first.finishClose()
        await drainMainActor()
        XCTAssertEqual(clients.clients.count, 2)
        XCTAssertEqual(clients.activeClientCount, 1)
        let replacement = clients.clients[1]
        replacement.validateSavedHostKey()
        replacement.becomeReady()
        await drainMainActor()
        XCTAssertEqual(controller.state, .connected)

        terminal.sendText("remote-two\r")
        XCTAssertEqual(replacement.sentBytes, [Array("remote-two\r".utf8)])
        terminal.setMode(.local)
        controller.disconnect()
        XCTAssertEqual(clients.activeClientCount, 0)
        XCTAssertFalse(terminal.receiveRemoteBytes(Array("late-output".utf8)))
        terminal.sendText("touch local.txt\r")
        await terminal.suspendLocalInputAndDrain()
        terminal.resumeLocalInput()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("local.txt").path))
        XCTAssertEqual(replacement.sentBytes, [Array("remote-two\r".utf8)])
    }

    func testModeAndRootGenerationInvalidatePendingDeletion() async throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Delete-First-\(UUID().uuidString)", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Delete-Second-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        let target = firstRoot.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let terminal = TerminalSessionCoordinator(rootURL: firstRoot)
        var presentedRequest: DeletionConfirmationRequest?
        terminal.onDeletionConfirmationChanged = { presentedRequest = $0 }

        terminal.sendText("rm keep.txt\r")
        await terminal.suspendLocalInputAndDrain()
        terminal.resumeLocalInput()
        let modeStaleRequest = try XCTUnwrap(presentedRequest)
        terminal.setMode(.ssh)
        terminal.confirmDeletion(modeStaleRequest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(presentedRequest)

        terminal.setMode(.local)
        terminal.sendText("rm keep.txt\r")
        await terminal.suspendLocalInputAndDrain()
        terminal.resumeLocalInput()
        let rootStaleRequest = try XCTUnwrap(presentedRequest)
        await terminal.suspendLocalInputAndDrain()
        terminal.installLocalRoot(secondRoot)
        terminal.resumeLocalInput()
        terminal.confirmDeletion(rootStaleRequest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(presentedRequest)
    }

    func testFailedFolderReplacementAndRestorationReconcilesTerminalToDocuments() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Scope-Fallback-\(UUID().uuidString)", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let previous = base.appendingPathComponent("Previous", isDirectory: true)
        let replacement = base.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let access = BoundaryFolderAccess()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiteTerm.Scope.\(UUID().uuidString)"))
        let store = FolderAuthorizationStore(
            documentsURL: documents,
            defaults: defaults,
            resourceAccess: access.dependencies
        )
        let model = AppModel(
            folderAuthorizationStore: store,
            secrets: KeychainStore(service: "com.liteterm.tests.scope.\(UUID().uuidString)")
        )

        await model.selectExternalFolder(previous)
        XCTAssertEqual(model.terminalSession.activeWorkspaceID, previous.path)
        access.failAllStarts = true

        await model.selectExternalFolder(replacement)

        XCTAssertEqual(access.stopCounts[previous], 1)
        XCTAssertEqual(access.startCounts[previous], 2)
        XCTAssertEqual(store.activeRootURL, documents)
        XCTAssertTrue(store.needsReauthorization)
        XCTAssertEqual(model.terminalSession.activeWorkspaceID, documents.path)
        XCTAssertEqual(model.activeWorkspaceName, "Documents")
        XCTAssertNotNil(model.authorizationErrorMessage)
    }

    func testAppModelRoutesBackgroundSafetyBeforeLatestCoalescedFolderIntent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Workspace-Scheduler-\(UUID().uuidString)", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let previous = base.appendingPathComponent("Previous", isDirectory: true)
        let superseded = base.appendingPathComponent("Superseded", isDirectory: true)
        let latest = base.appendingPathComponent("Latest", isDirectory: true)
        for url in [documents, previous, superseded, latest] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let access = BoundaryFolderAccess()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiteTerm.Scheduler.\(UUID().uuidString)"))
        let store = FolderAuthorizationStore(
            documentsURL: documents,
            defaults: defaults,
            resourceAccess: access.dependencies
        )
        let scheduler = WorkspaceTransitionScheduler()
        let gate = BoundaryOperationGate()
        let model = AppModel(
            folderAuthorizationStore: store,
            secrets: KeychainStore(service: "com.liteterm.tests.scheduler.\(UUID().uuidString)"),
            workspaceTransitionScheduler: scheduler
        )
        await model.selectExternalFolder(previous)

        scheduler.submitNormal { await gate.wait() }
        await gate.waitUntilStarted()
        for _ in 0..<100 {
            model.completeFolderSelection(superseded)
        }
        model.didEnterBackground()
        model.completeFolderSelection(latest)

        XCTAssertEqual(scheduler.retainedTransitionCount, 3)
        await gate.release()
        await scheduler.drain()

        XCTAssertEqual(access.stopCounts[previous], 1)
        XCTAssertNil(access.startCounts[superseded])
        XCTAssertEqual(access.startCounts[latest], 1)
        XCTAssertEqual(store.activeRootURL, latest)
        XCTAssertEqual(model.terminalSession.activeWorkspaceID, latest.path)
        XCTAssertEqual(scheduler.retainedTransitionCount, 0)
    }

    func testCoordinatorPassesCommandCostAndRejectsBeyondTheBlockedQueueBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Queue-Boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let queue = LocalOperationQueue(maximumPendingOperations: 2, maximumPendingCost: 5)
        let gate = BoundaryOperationGate()
        XCTAssertTrue(queue.enqueue(operationCost: 2) {
            await gate.wait()
        })
        await gate.waitUntilStarted()
        let terminal = TerminalSessionCoordinator(rootURL: root, localOperationQueue: queue)

        XCTAssertTrue(terminal.runLocalCommand("pwd"))
        XCTAssertFalse(terminal.runLocalCommand("ls"))
        XCTAssertEqual(queue.pendingOperationCount, 2)
        XCTAssertEqual(queue.pendingOperationCost, 5)

        await gate.release()
        await terminal.suspendLocalInputAndDrain()
        XCTAssertEqual(queue.pendingOperationCount, 0)
        XCTAssertEqual(queue.pendingOperationCost, 0)
        terminal.resumeLocalInput()
        XCTAssertTrue(terminal.runLocalCommand("ls"))
        await terminal.suspendLocalInputAndDrain()
        terminal.resumeLocalInput()
    }

    func testDuplicateAuthenticationSuccessClaimsOnlyOneChildSession() {
        var gate = SSHChildSessionCreationGate()

        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testConnectedRekeyReplacementCompletesPromiseOnceAndResumesConnected() async throws {
        let host = try makeHost()
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)

        let originalKey = try deterministicKey(byte: 1)
        let replacementKey = try deterministicKey(byte: 2)
        let originalFingerprint = try SSHHostKeyValidator.openSSHSHA256Fingerprint(for: originalKey.publicKey)
        let replacementFingerprint = try SSHHostKeyValidator.openSSHSHA256Fingerprint(for: replacementKey.publicKey)
        try secrets.set(Data(originalFingerprint.utf8), for: host.id, kind: .trustedFingerprint)

        let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
        let clients = BoundaryClientStore()
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient
        )
        controller.scenePhaseChanged(.active)
        controller.connect(host: host)
        let client = try XCTUnwrap(clients.clients.first)
        client.validateSavedHostKey()
        await drainMainActor()
        client.becomeReady()
        await drainMainActor()
        XCTAssertEqual(controller.state, .connected)

        client.requireTrust(replacementFingerprint, kind: .replacement)
        await drainMainActor()
        XCTAssertEqual(controller.state, .awaitingHostTrust)
        XCTAssertEqual(controller.pendingHostTrust?.resumeConnectedSession, true)
        controller.confirmHostTrust()
        await drainMainActor()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(
            try secrets.data(for: host.id, kind: .trustedFingerprint),
            Data(replacementFingerprint.utf8)
        )

        let loop = EmbeddedEventLoop()
        let trustKind = NIOLockedValueBox<SSHHostTrustKind?>(nil)
        let validator = SSHHostKeyValidator(
            storedFingerprint: .valid(originalFingerprint),
            onTrustRequired: { _, kind in trustKind.withLockedValue { $0 = kind } },
            onValidated: {}
        )
        let completion = PromiseCompletionBox()
        let promise = loop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { completion.record($0) }
        validator.validateHostKey(
            hostKey: replacementKey.publicKey,
            validationCompletePromise: promise
        )
        loop.run()
        XCTAssertEqual(trustKind.withLockedValue { $0 }, .replacement)
        XCTAssertEqual(completion.count, 0)

        validator.confirmPendingTrust()
        loop.run()
        validator.cancelPendingValidation()
        loop.run()
        XCTAssertEqual(completion.count, 1)
        XCTAssertTrue(completion.succeeded)

        let cancelled = PromiseCompletionBox()
        let cancelValidator = SSHHostKeyValidator(
            storedFingerprint: .absent,
            onTrustRequired: { _, _ in },
            onValidated: {}
        )
        let cancelPromise = loop.makePromise(of: Void.self)
        cancelPromise.futureResult.whenComplete { cancelled.record($0) }
        cancelValidator.validateHostKey(
            hostKey: originalKey.publicKey,
            validationCompletePromise: cancelPromise
        )
        loop.run()
        XCTAssertEqual(cancelled.count, 0)
        cancelValidator.cancelPendingValidation()
        loop.run()
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertFalse(cancelled.succeeded)
    }

    func testControllerAcknowledgesAfterMainActorDelivery() async throws {
        let host = try makeHost()
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)
        let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
        terminal.setMode(.ssh)
        let clients = BoundaryClientStore()
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient
        )
        controller.scenePhaseChanged(.active)
        controller.connect(host: host)
        let acknowledged = NIOLockedValueBox(false)
        try XCTUnwrap(clients.clients.first).deliver(
            [0x1B, 0x5D, 0x35, 0x32, 0x3B, 0x63, 0x07],
            acknowledged: acknowledged
        )
        XCTAssertFalse(acknowledged.withLockedValue { $0 })
        await drainMainActor()
        XCTAssertTrue(acknowledged.withLockedValue { $0 })
    }

    func testProductionTerminalHandlerCoalescesOneReadCycleBeforeAcknowledgement() throws {
        XCTAssertTrue(
            SSHTerminalHandler.defaultMaximumPendingOutputBytes >= 8 * 1024 * 1024
        )
        let recorder = BoundarySSHOutboundRecorder()
        let deliveries = BoundarySSHOutputRecorder()
        let terminalHandler = SSHTerminalHandler(
            dimensions: SSHTerminalDimensions(columns: 80, rows: 24),
            onReady: {},
            onBytes: deliveries.record,
            onError: deliveries.record(error:),
            onClosed: deliveries.recordClosed
        )
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            handlers: [recorder, terminalHandler],
            loop: loop
        )
        defer { _ = try? channel.finish() }
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 22)
        try channel.connect(to: address).wait()
        let readsBeforeOutput = recorder.readCount

        channel.pipeline.fireChannelRead(
            sshChannelData([0x41, 0x42], allocator: channel.allocator)
        )
        channel.pipeline.fireChannelRead(
            sshChannelData([0x43, 0x44], allocator: channel.allocator)
        )
        XCTAssertTrue(deliveries.bytes.isEmpty)
        XCTAssertTrue(deliveries.errors.isEmpty)
        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireChannelReadComplete()

        XCTAssertEqual(deliveries.bytes, [[0x41, 0x42, 0x43, 0x44]])
        XCTAssertEqual(deliveries.errors.count, 0)
        XCTAssertEqual(deliveries.closedCount, 0)
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)

        try XCTUnwrap(deliveries.acknowledgements.first)()
        loop.run()
        XCTAssertEqual(recorder.readCount, readsBeforeOutput + 1)
    }

    func testProductionTerminalHandlerSplitsBatchesAndRejectsStaleAcknowledgements() throws {
        let recorder = BoundarySSHOutboundRecorder()
        let deliveries = BoundarySSHOutputRecorder()
        let terminalHandler = SSHTerminalHandler(
            dimensions: SSHTerminalDimensions(columns: 80, rows: 24),
            maximumPendingOutputBytes: 8,
            maximumDeliveryBatchBytes: 3,
            onReady: {},
            onBytes: deliveries.record,
            onError: deliveries.record(error:),
            onClosed: deliveries.recordClosed
        )
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            handlers: [recorder, terminalHandler],
            loop: loop
        )
        defer { _ = try? channel.finish() }
        try channel.connect(
            to: SocketAddress(ipAddress: "127.0.0.1", port: 22)
        ).wait()
        let readsBeforeOutput = recorder.readCount

        channel.pipeline.fireChannelRead(
            sshChannelData([0, 1, 2, 3], allocator: channel.allocator)
        )
        channel.pipeline.fireChannelRead(
            sshChannelData([4, 5, 6, 7], allocator: channel.allocator)
        )
        channel.pipeline.fireChannelReadComplete()

        XCTAssertEqual(deliveries.bytes, [[0, 1, 2]])
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)
        let firstAcknowledgement = try XCTUnwrap(deliveries.acknowledgements.first)
        firstAcknowledgement()
        loop.run()
        XCTAssertEqual(deliveries.bytes, [[0, 1, 2], [3, 4, 5]])
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)

        firstAcknowledgement()
        loop.run()
        XCTAssertEqual(deliveries.bytes, [[0, 1, 2], [3, 4, 5]])
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)

        let secondAcknowledgement = try XCTUnwrap(deliveries.acknowledgements.last)
        secondAcknowledgement()
        loop.run()
        XCTAssertEqual(deliveries.bytes, [[0, 1, 2], [3, 4, 5], [6, 7]])
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)

        try XCTUnwrap(deliveries.acknowledgements.last)()
        loop.run()
        XCTAssertEqual(recorder.readCount, readsBeforeOutput + 1)
        XCTAssertTrue(deliveries.errors.isEmpty)
        XCTAssertTrue(channel.isActive)
    }

    func testProductionTerminalHandlerFailsClosedAtCumulativePendingCap() throws {
        let recorder = BoundarySSHOutboundRecorder()
        let deliveries = BoundarySSHOutputRecorder()
        let terminalHandler = SSHTerminalHandler(
            dimensions: SSHTerminalDimensions(columns: 80, rows: 24),
            maximumPendingOutputBytes: 5,
            maximumDeliveryBatchBytes: 3,
            onReady: {},
            onBytes: deliveries.record,
            onError: deliveries.record(error:),
            onClosed: deliveries.recordClosed
        )
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            handlers: [recorder, terminalHandler],
            loop: loop
        )
        defer { _ = try? channel.finish() }
        try channel.connect(
            to: SocketAddress(ipAddress: "127.0.0.1", port: 22)
        ).wait()
        let readsBeforeOutput = recorder.readCount

        channel.pipeline.fireChannelRead(
            sshChannelData([0, 1, 2], allocator: channel.allocator)
        )
        channel.pipeline.fireChannelRead(
            sshChannelData([3, 4, 5], allocator: channel.allocator)
        )
        loop.run()

        XCTAssertEqual(deliveries.bytes, [])
        XCTAssertEqual(deliveries.errors.count, 1)
        guard
            let error = deliveries.errors.first as? SSHTerminalHandlerError,
            case .outputBackpressureOverflow = error
        else {
            return XCTFail("Expected cumulative output overflow")
        }
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(deliveries.closedCount, 1)
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)
    }

    func testProductionTerminalHandlerClearsQueuedOutputWhenChannelCloses() throws {
        let recorder = BoundarySSHOutboundRecorder()
        let deliveries = BoundarySSHOutputRecorder()
        let terminalHandler = SSHTerminalHandler(
            dimensions: SSHTerminalDimensions(columns: 80, rows: 24),
            maximumPendingOutputBytes: 8,
            maximumDeliveryBatchBytes: 3,
            onReady: {},
            onBytes: deliveries.record,
            onError: deliveries.record(error:),
            onClosed: deliveries.recordClosed
        )
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            handlers: [recorder, terminalHandler],
            loop: loop
        )
        defer { _ = try? channel.finish() }
        try channel.connect(
            to: SocketAddress(ipAddress: "127.0.0.1", port: 22)
        ).wait()
        let readsBeforeOutput = recorder.readCount

        channel.pipeline.fireChannelRead(
            sshChannelData([0, 1, 2, 3, 4, 5], allocator: channel.allocator)
        )
        channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(deliveries.bytes, [[0, 1, 2]])
        let acknowledgement = try XCTUnwrap(deliveries.acknowledgements.first)

        try channel.close().wait()
        loop.run()
        XCTAssertEqual(deliveries.closedCount, 1)
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)
        acknowledgement()
        loop.run()
        XCTAssertEqual(deliveries.bytes, [[0, 1, 2]])
        XCTAssertEqual(recorder.readCount, readsBeforeOutput)
        XCTAssertTrue(deliveries.errors.isEmpty)
    }

    func testInactiveConnectStartsNoNetworkAndActiveResumesOnlyEnabledHost() async throws {
        let host = try makeHost(reconnectPreference: .enabled)
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)
        let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
        let clients = BoundaryClientStore()
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient,
            reconnectSleep: { _ in }
        )

        controller.scenePhaseChanged(.inactive)
        controller.connect(host: host)
        XCTAssertEqual(clients.clients.count, 0)
        XCTAssertEqual(controller.state, .disconnected)

        controller.scenePhaseChanged(.active)
        await drainMainActor()
        XCTAssertEqual(clients.clients.count, 1)
        XCTAssertTrue(clients.clients[0].didConnect)
        controller.disconnect()

        let disabledHost = try makeHost(reconnectPreference: .disabled)
        defer { clean(secrets, hostID: disabledHost.id) }
        try installPassword(in: secrets, hostID: disabledHost.id)
        let disabledClients = BoundaryClientStore()
        let disabledController = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: disabledClients.makeClient,
            reconnectSleep: { _ in }
        )
        disabledController.scenePhaseChanged(.inactive)
        disabledController.connect(host: disabledHost)
        disabledController.scenePhaseChanged(.active)
        await drainMainActor()
        XCTAssertEqual(disabledClients.clients.count, 0)
        XCTAssertEqual(disabledController.state, .disconnected)
    }

    func testLocalTerminalSizeBecomesInitialPTYSizeAndNormalizesMinimums() async throws {
        let host = try makeHost()
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)
        let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
        terminal.terminalSizeChanged(columns: 132, rows: 43)
        XCTAssertEqual(terminal.currentTerminalSize.columns, 132)
        XCTAssertEqual(terminal.currentTerminalSize.rows, 43)

        let clients = BoundaryClientStore()
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient
        )
        controller.scenePhaseChanged(.active)
        controller.connect(host: host)
        let configuration = try XCTUnwrap(clients.clients.first?.configuration)
        XCTAssertEqual(configuration.terminalDimensions.columns, 132)
        XCTAssertEqual(configuration.terminalDimensions.rows, 43)
        let request = SSHTerminalHandler.pseudoTerminalRequest(
            dimensions: configuration.terminalDimensions
        )
        XCTAssertEqual(request.term, "xterm-256color")
        XCTAssertEqual(request.terminalCharacterWidth, 132)
        XCTAssertEqual(request.terminalRowHeight, 43)

        terminal.terminalSizeChanged(columns: 0, rows: -7)
        XCTAssertEqual(terminal.currentTerminalSize.columns, 1)
        XCTAssertEqual(terminal.currentTerminalSize.rows, 1)
        controller.disconnect()
    }

    func testMalformedAndNonUTF8StoredFingerprintsAreCorruptNotAbsent() throws {
        for storedData in [Data("malformed".utf8), Data([0xFF, 0xFE])] {
            let host = try makeHost()
            let secrets = makeSecrets()
            defer { clean(secrets, hostID: host.id) }
            try installPassword(in: secrets, hostID: host.id)
            try secrets.set(storedData, for: host.id, kind: .trustedFingerprint)
            let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
            let clients = BoundaryClientStore()
            let controller = SSHSessionController(
                secrets: secrets,
                terminalSession: terminal,
                clientFactory: clients.makeClient
            )

            controller.scenePhaseChanged(.active)
            controller.connect(host: host)
            XCTAssertEqual(clients.clients.first?.configuration.storedFingerprint, .corrupt)
            controller.disconnect()
        }

        let loop = EmbeddedEventLoop()
        let trustKind = NIOLockedValueBox<SSHHostTrustKind?>(nil)
        let validator = SSHHostKeyValidator(
            storedFingerprint: .corrupt,
            onTrustRequired: { _, kind in trustKind.withLockedValue { $0 = kind } },
            onValidated: {}
        )
        let promise = loop.makePromise(of: Void.self)
        let completion = PromiseCompletionBox()
        promise.futureResult.whenComplete { completion.record($0) }
        let key = try deterministicKey(byte: 3)
        validator.validateHostKey(hostKey: key.publicKey, validationCompletePromise: promise)
        loop.run()
        XCTAssertEqual(trustKind.withLockedValue { $0 }, .replacement)
        XCTAssertEqual(completion.count, 0)
        validator.rejectPendingTrust(as: .hostKeyMismatch)
        loop.run()
        XCTAssertEqual(completion.count, 1)
        XCTAssertFalse(completion.succeeded)
    }

    func testStaleCallbacksAcknowledgeAndReplacementWaitsForTeardown() async throws {
        let host = try makeHost()
        let secrets = makeSecrets()
        defer { clean(secrets, hostID: host.id) }
        try installPassword(in: secrets, hostID: host.id)
        let terminal = TerminalSessionCoordinator(rootURL: URL(fileURLWithPath: "/tmp"))
        terminal.setMode(.ssh)
        let clients = BoundaryClientStore()
        clients.delayFirstClose = true
        let controller = SSHSessionController(
            secrets: secrets,
            terminalSession: terminal,
            clientFactory: clients.makeClient
        )

        controller.scenePhaseChanged(.active)
        controller.connect(host: host)
        let staleClient = try XCTUnwrap(clients.clients.first)
        controller.connect(host: host)
        XCTAssertEqual(clients.clients.count, 1)
        staleClient.validateSavedHostKey()
        await drainMainActor()
        XCTAssertEqual(controller.state, .connecting)

        let staleAcknowledged = NIOLockedValueBox(false)
        staleClient.deliver([0x41], acknowledged: staleAcknowledged)
        await drainMainActor()
        XCTAssertTrue(staleAcknowledged.withLockedValue { $0 })
        XCTAssertEqual(clients.clients.count, 1)

        staleClient.finishClose()
        await drainMainActor()
        XCTAssertEqual(clients.clients.count, 2)
        XCTAssertTrue(clients.clients[1].didConnect)
        controller.disconnect()
    }

    private func makeSecrets() -> KeychainStore {
        KeychainStore(service: "com.liteterm.tests.ssh-boundary.\(UUID().uuidString)")
    }

    private func makeHost(
        reconnectPreference: HostReconnectPreference = .enabled
    ) throws -> SSHHost {
        try SSHHost(
            label: "Boundary test",
            hostname: "example.invalid",
            username: "tester",
            authenticationKind: .password,
            reconnectPreference: reconnectPreference
        )
    }

    private func installPassword(in secrets: KeychainStore, hostID: UUID) throws {
        try secrets.set(Data("test-only".utf8), for: hostID, kind: .password)
    }

    private func clean(_ secrets: KeychainStore, hostID: UUID) {
        for kind in HostSecretKind.allCases {
            try? secrets.delete(for: hostID, kind: kind)
        }
    }

    private func deterministicKey(byte: UInt8) throws -> NIOSSHPrivateKey {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: byte, count: 32)
        )
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    private func drainMainActor() async {
        for _ in 0..<6 {
            await Task.yield()
        }
    }
}

private actor BoundaryOperationGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class BoundarySSHOutboundRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Never

    private(set) var readCount = 0

    func read(context: ChannelHandlerContext) {
        readCount += 1
        context.read()
    }

    func triggerUserOutboundEvent(
        context: ChannelHandlerContext,
        event: Any,
        promise: EventLoopPromise<Void>?
    ) {
        promise?.succeed(())
    }
}

private final class BoundarySSHOutputRecorder: @unchecked Sendable {
    private let storage = NIOLockedValueBox(
        (bytes: [[UInt8]](), acknowledgements: [@Sendable () -> Void](), errors: [Error](), closed: 0)
    )

    var bytes: [[UInt8]] { storage.withLockedValue { $0.bytes } }
    var acknowledgements: [@Sendable () -> Void] {
        storage.withLockedValue { $0.acknowledgements }
    }
    var errors: [Error] { storage.withLockedValue { $0.errors } }
    var closedCount: Int { storage.withLockedValue { $0.closed } }

    func record(_ bytes: [UInt8], acknowledgement: @escaping @Sendable () -> Void) {
        storage.withLockedValue { state in
            state.bytes.append(bytes)
            state.acknowledgements.append(acknowledgement)
        }
    }

    func record(error: Error) {
        storage.withLockedValue { $0.errors.append(error) }
    }

    func recordClosed() {
        storage.withLockedValue { $0.closed += 1 }
    }
}

private func sshChannelData(
    _ bytes: [UInt8],
    allocator: ByteBufferAllocator
) -> SSHChannelData {
    var buffer = allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    return SSHChannelData(type: .channel, data: .byteBuffer(buffer))
}

private final class BoundaryClientStore {
    var clients: [BoundarySSHClient] = []
    var delayFirstClose = false

    var activeClientCount: Int {
        clients.filter { $0.didConnect && !$0.didFinishClose }.count
    }

    func makeClient(configuration: LiteTermSSHClientConfiguration) -> any SSHClientTransport {
        let client = BoundarySSHClient(configuration: configuration)
        if delayFirstClose, clients.isEmpty {
            client.completesCloseImmediately = false
        }
        clients.append(client)
        return client
    }
}

@MainActor
private final class BoundaryFolderAccess {
    var failAllStarts = false
    private(set) var startCounts: [URL: Int] = [:]
    private(set) var stopCounts: [URL: Int] = [:]

    var dependencies: FolderAuthorizationDependencies {
        FolderAuthorizationDependencies(
            startAccessing: { [weak self] url in
                guard let self else { return false }
                self.startCounts[url, default: 0] += 1
                return !self.failAllStarts
            },
            stopAccessing: { [weak self] url in
                self?.stopCounts[url, default: 0] += 1
            },
            isDirectory: { _ in true },
            makeBookmark: { _ in Data("bookmark".utf8) }
        )
    }
}

private final class BoundarySSHClient: SSHClientTransport, @unchecked Sendable {
    let configuration: LiteTermSSHClientConfiguration
    private(set) var didConnect = false
    private(set) var didFinishClose = false
    private(set) var sentBytes: [[UInt8]] = []
    var completesCloseImmediately = true
    private var pendingClose: (@Sendable () -> Void)?

    init(configuration: LiteTermSSHClientConfiguration) {
        self.configuration = configuration
    }

    func connect() {
        didConnect = true
    }

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }

    func resize(columns: Int, rows: Int) {}

    func confirmHostTrust() {
        configuration.callbacks.hostKeyValidated()
    }

    func rejectHostTrust(as failure: SSHClientFailure) {
        configuration.callbacks.connectionClosed(failure)
    }

    func close(completion: @escaping @Sendable () -> Void) {
        if completesCloseImmediately {
            didFinishClose = true
            completion()
        } else {
            pendingClose = completion
        }
    }

    func finishClose() {
        let completion = pendingClose
        pendingClose = nil
        didFinishClose = true
        completion?()
    }

    func validateSavedHostKey() {
        configuration.callbacks.hostKeyValidated()
    }

    func becomeReady() {
        configuration.callbacks.terminalReady()
    }

    func requireTrust(_ fingerprint: String, kind: SSHHostTrustKind) {
        configuration.callbacks.hostTrustRequired(fingerprint, kind)
    }

    func deliver(_ bytes: [UInt8], acknowledged: NIOLockedValueBox<Bool>) {
        configuration.callbacks.receiveBytes(bytes) {
            acknowledged.withLockedValue { $0 = true }
        }
    }
}

private final class PromiseCompletionBox: @unchecked Sendable {
    private let storage = NIOLockedValueBox((count: 0, succeeded: false))

    var count: Int { storage.withLockedValue { $0.count } }
    var succeeded: Bool { storage.withLockedValue { $0.succeeded } }

    func record(_ result: Result<Void, Error>) {
        storage.withLockedValue { state in
            state.count += 1
            if case .success = result {
                state.succeeded = true
            }
        }
    }
}
