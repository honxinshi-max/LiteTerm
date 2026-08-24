import Crypto
import LiteTermCore
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOSSH
import SwiftUI
import XCTest
@testable import LiteTerm

@MainActor
final class SSHSessionBoundaryTests: XCTestCase {
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

    func testOutputAdmissionIsBoundedAndControllerAcknowledgesAfterMainActorDelivery() async throws {
        var gate = SSHOutputDeliveryGate(maximumChunkBytes: 4)
        let admission = gate.admit(byteCount: 4)
        guard case .accepted(let token) = admission else {
            return XCTFail("Expected first bounded output chunk to be accepted")
        }
        XCTAssertEqual(gate.admit(byteCount: 1), .overflow)
        XCTAssertTrue(gate.acknowledge(token: token))
        XCTAssertFalse(gate.acknowledge(token: token))
        XCTAssertEqual(gate.admit(byteCount: 5), .overflow)

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

private final class BoundaryClientStore {
    var clients: [BoundarySSHClient] = []
    var delayFirstClose = false

    func makeClient(configuration: LiteTermSSHClientConfiguration) -> any SSHClientTransport {
        let client = BoundarySSHClient(configuration: configuration)
        if delayFirstClose, clients.isEmpty {
            client.completesCloseImmediately = false
        }
        clients.append(client)
        return client
    }
}

private final class BoundarySSHClient: SSHClientTransport, @unchecked Sendable {
    let configuration: LiteTermSSHClientConfiguration
    private(set) var didConnect = false
    var completesCloseImmediately = true
    private var pendingClose: (@Sendable () -> Void)?

    init(configuration: LiteTermSSHClientConfiguration) {
        self.configuration = configuration
    }

    func connect() {
        didConnect = true
    }

    func send(_ bytes: [UInt8]) {}

    func resize(columns: Int, rows: Int) {}

    func confirmHostTrust() {
        configuration.callbacks.hostKeyValidated()
    }

    func rejectHostTrust(as failure: SSHClientFailure) {
        configuration.callbacks.connectionClosed(failure)
    }

    func close(completion: @escaping @Sendable () -> Void) {
        if completesCloseImmediately {
            completion()
        } else {
            pendingClose = completion
        }
    }

    func finishClose() {
        let completion = pendingClose
        pendingClose = nil
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
