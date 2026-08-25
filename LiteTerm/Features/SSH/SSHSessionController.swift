import Combine
import Foundation
import LiteTermCore
import SwiftUI

struct SSHHostTrustRequest: Identifiable, Equatable {
    let hostID: UUID
    let hostLabel: String
    let fingerprint: String
    let kind: SSHHostTrustKind
    let generation: UInt64
    let resumeConnectedSession: Bool

    var id: String {
        "\(generation):\(hostID.uuidString):\(fingerprint)"
    }
}

@MainActor
final class SSHSessionController: ObservableObject {
    typealias ClientFactory = (LiteTermSSHClientConfiguration) -> any SSHClientTransport
    typealias ReconnectSleep = @Sendable (Duration) async throws -> Void

    @Published private(set) var state: SSHConnectionState = .disconnected
    @Published private(set) var activeHostID: UUID?
    @Published var pendingHostTrust: SSHHostTrustRequest?

    private let secrets: any HostSecretStoring
    private let keyManager: Ed25519KeyManager
    private let terminalSession: TerminalSessionCoordinator
    private let clientFactory: ClientFactory
    private let reconnectSleep: ReconnectSleep

    private var reducer = SSHConnectionStateReducer()
    private var reconnect = SSHReconnectOrchestrator(isEnabled: false)
    private var currentHost: SSHHost?
    private var client: (any SSHClientTransport)?
    private var retryTask: Task<Void, Never>?
    private var closingClientCount = 0
    private var deferredStart: (host: SSHHost, generation: UInt64)?
    private var terminalDimensions = SSHTerminalDimensions.fallback
    private var sceneIsActive = false

    init(
        secrets: any HostSecretStoring,
        terminalSession: TerminalSessionCoordinator,
        clientFactory: @escaping ClientFactory = { SSHClient(configuration: $0) },
        reconnectSleep: @escaping ReconnectSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.secrets = secrets
        keyManager = Ed25519KeyManager(secrets: secrets)
        self.terminalSession = terminalSession
        self.clientFactory = clientFactory
        self.reconnectSleep = reconnectSleep
    }

    var failurePresentation: SSHFailurePresentation? {
        guard case .failed(let category) = state else { return nil }
        return category.presentation
    }

    func connect(host: SSHHost) {
        retryTask?.cancel()
        retryTask = nil
        deferredStart = nil

        let previousClient = client
        client = nil
        pendingHostTrust = nil
        currentHost = host
        activeHostID = host.id
        terminalSession.selectSSHHost(host.id)
        reconnect = SSHReconnectOrchestrator(
            isEnabled: host.reconnectPreference == .enabled
        )
        reconnect.userInitiatedConnection()
        if !sceneIsActive {
            _ = reconnect.scenePhaseChanged(isActive: false)
        }
        terminalDimensions = terminalSession.currentTerminalSize

        let generation = sceneIsActive
            ? reducer.beginConnection()
            : reducer.disconnect()
        if sceneIsActive {
            terminalSession.beginSSHConnection(generation: generation, state: reducer.state)
        } else {
            terminalSession.disconnectSSH()
        }
        publishState()

        if let previousClient {
            retire(previousClient)
        }
        if sceneIsActive {
            startClient(for: host, generation: generation)
        }
    }

    func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        deferredStart = nil
        reconnect.manualDisconnect()
        pendingHostTrust = nil
        currentHost = nil
        activeHostID = nil
        _ = reducer.disconnect()
        terminalSession.disconnectSSH()
        publishState()

        let previousClient = client
        client = nil
        if let previousClient {
            retire(previousClient)
        }
    }

    func retryCurrentHost() {
        guard
            sceneIsActive,
            client == nil,
            let host = currentHost,
            let generation = reducer.beginManualRetry()
        else {
            return
        }
        retryTask?.cancel()
        retryTask = nil
        deferredStart = nil
        pendingHostTrust = nil
        reconnect.userInitiatedConnection()
        terminalSession.beginSSHConnection(generation: generation, state: reducer.state)
        publishState()
        startClient(for: host, generation: generation)
    }

    func send(_ bytes: [UInt8]) {
        guard state == .connected else { return }
        client?.send(bytes)
    }

    func resize(columns: Int, rows: Int) {
        terminalDimensions = SSHTerminalDimensions(columns: columns, rows: rows)
        client?.resize(columns: terminalDimensions.columns, rows: terminalDimensions.rows)
    }

    func confirmHostTrust() {
        guard
            let request = pendingHostTrust,
            request.generation == reducer.generation,
            request.hostID == activeHostID
        else {
            return
        }

        do {
            try secrets.set(
                Data(request.fingerprint.utf8),
                for: request.hostID,
                kind: .trustedFingerprint
            )
            client?.confirmHostTrust()
        } catch {
            client?.rejectHostTrust(as: .credentialUnavailable)
        }
    }

    func cancelHostTrust() {
        guard let request = pendingHostTrust, request.generation == reducer.generation else {
            return
        }
        client?.rejectHostTrust(
            as: request.kind == .replacement ? .hostKeyMismatch : .trustCancelled
        )
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            guard let directive = reconnect.scenePhaseChanged(isActive: true) else { return }
            scheduleReconnect(directive)

        case .inactive, .background:
            sceneIsActive = false
            _ = reconnect.scenePhaseChanged(isActive: false)
            retryTask?.cancel()
            retryTask = nil
            deferredStart = nil
            pendingHostTrust = nil
            let previousClient = client
            client = nil
            _ = reducer.disconnect()
            terminalSession.disconnectSSH()
            publishState()
            if let previousClient {
                retire(previousClient)
            }

        @unknown default:
            break
        }
    }

    private func startClient(for host: SSHHost, generation: UInt64) {
        guard
            reducer.generation == generation,
            currentHost?.id == host.id,
            client == nil,
            sceneIsActive
        else {
            return
        }
        guard closingClientCount == 0 else {
            deferredStart = (host, generation)
            return
        }
        deferredStart = nil

        do {
            let credential = try credential(for: host)
            let storedFingerprint = SSHStoredHostFingerprint.classify(
                storedData: try secrets.data(for: host.id, kind: .trustedFingerprint)
            )
            let callbacks = SSHClientCallbacks(
                hostTrustRequired: { [weak self] fingerprint, kind in
                    Task { @MainActor [weak self] in
                        self?.hostTrustRequired(
                            fingerprint: fingerprint,
                            kind: kind,
                            host: host,
                            generation: generation
                        )
                    }
                },
                hostKeyValidated: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.hostKeyValidated(generation: generation)
                    }
                },
                terminalReady: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.terminalReady(generation: generation)
                    }
                },
                receiveBytes: { [weak self] bytes, acknowledge in
                    Task { @MainActor [weak self] in
                        defer { acknowledge() }
                        guard let self, self.reducer.generation == generation else { return }
                        self.terminalSession.receiveRemoteBytes(bytes)
                    }
                },
                connectionClosed: { [weak self] failure in
                    Task { @MainActor [weak self] in
                        self?.connectionClosed(failure, generation: generation)
                    }
                }
            )
            let configuration = LiteTermSSHClientConfiguration(
                host: host,
                credential: credential,
                storedFingerprint: storedFingerprint,
                terminalDimensions: terminalDimensions,
                callbacks: callbacks
            )
            let nextClient = clientFactory(configuration)
            client = nextClient
            nextClient.connect()
        } catch {
            failCredentialPreparation(generation: generation)
        }
    }

    private func credential(for host: SSHHost) throws -> SSHClientCredential {
        switch host.authenticationKind {
        case .password:
            guard
                let data = try secrets.data(for: host.id, kind: .password),
                let password = String(data: data, encoding: .utf8),
                !password.isEmpty
            else {
                throw Ed25519KeyManagerError.keyNotGenerated
            }
            return .password(password)

        case .generatedKey:
            return .generatedKey(try keyManager.privateKey(for: host.id))
        }
    }

    private func hostTrustRequired(
        fingerprint: String,
        kind: SSHHostTrustKind,
        host: SSHHost,
        generation: UInt64
    ) {
        let resumeConnectedSession = pendingHostTrust?.resumeConnectedSession
            ?? (reducer.state == .connected)
        guard
            currentHost?.id == host.id,
            reducer.reduce(.hostKeyValidationRequired, generation: generation)
        else {
            return
        }
        pendingHostTrust = SSHHostTrustRequest(
            hostID: host.id,
            hostLabel: host.label,
            fingerprint: fingerprint,
            kind: kind,
            generation: generation,
            resumeConnectedSession: resumeConnectedSession
        )
        publishState()
    }

    private func hostKeyValidated(generation: UInt64) {
        let event: SSHConnectionEvent = pendingHostTrust?.resumeConnectedSession == true
            ? .hostKeyRevalidated
            : .hostKeyValidated
        guard reducer.reduce(event, generation: generation) else { return }
        pendingHostTrust = nil
        publishState()
    }

    private func terminalReady(generation: UInt64) {
        guard reducer.reduce(.authenticationSucceeded, generation: generation) else { return }
        reconnect.connectionEstablished()
        publishState()
    }

    private func connectionClosed(_ failure: SSHClientFailure, generation: UInt64) {
        guard reducer.generation == generation else { return }
        client = nil
        pendingHostTrust = nil

        if failure == .transport,
           let directive = reconnect.connectionFailed(.transportLoss) {
            scheduleReconnect(directive)
            return
        }

        switch failure {
        case .remoteSessionEnded:
            reconnect.manualDisconnect()
        case .authenticationRejected:
            _ = reconnect.connectionFailed(.authenticationRejected)
        case .hostKeyMismatch:
            _ = reconnect.connectionFailed(.hostKeyMismatch)
        case .transport:
            _ = reconnect.connectionFailed(.transportLoss)
        case .credentialUnavailable, .trustCancelled, .protocolFailure:
            reconnect.manualDisconnect()
        }
        _ = reducer.reduce(.failed(failure.stateCategory), generation: generation)
        publishState()
    }

    private func scheduleReconnect(_ directive: SSHReconnectDirective) {
        guard let host = currentHost, sceneIsActive else { return }
        retryTask?.cancel()
        let generation = reducer.beginReconnect(attempt: directive.attempt)
        terminalSession.beginSSHConnection(generation: generation, state: reducer.state)
        publishState()
        let reconnectSleep = reconnectSleep
        retryTask = Task { @MainActor [weak self] in
            do {
                try await reconnectSleep(directive.delay)
            } catch {
                return
            }
            guard
                let self,
                !Task.isCancelled,
                self.reducer.generation == generation,
                self.currentHost?.id == host.id,
                self.sceneIsActive
            else {
                return
            }
            self.retryTask = nil
            self.startClient(for: host, generation: generation)
        }
    }

    private func failCredentialPreparation(generation: UInt64) {
        guard reducer.generation == generation else { return }
        reconnect.manualDisconnect()
        _ = reducer.reduce(.failed(.credentialUnavailable), generation: generation)
        publishState()
    }

    private func retire(_ retiringClient: any SSHClientTransport) {
        closingClientCount += 1
        retiringClient.close { [weak self] in
            Task { @MainActor [weak self] in
                self?.clientDidFinishClosing()
            }
        }
    }

    private func clientDidFinishClosing() {
        precondition(closingClientCount > 0, "Unbalanced SSH client teardown")
        closingClientCount -= 1
        guard closingClientCount == 0, let deferredStart else { return }
        self.deferredStart = nil
        startClient(for: deferredStart.host, generation: deferredStart.generation)
    }

    private func publishState() {
        state = reducer.state
        terminalSession.updateSSHConnectionState(state, generation: reducer.generation)
        let status: RemoteTerminalStatus
        switch state {
        case .disconnected:
            status = .disconnected
        case .connecting:
            status = .connecting
        case .awaitingHostTrust:
            status = .awaitingHostTrust
        case .authenticating:
            status = .authenticating
        case .connected:
            status = .connected
        case .reconnecting:
            status = .reconnecting
        case .failed:
            status = .failed
        }
        terminalSession.updateRemoteStatus(status)
    }
}
