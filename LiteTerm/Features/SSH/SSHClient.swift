import Dispatch
import Foundation
import LiteTermCore
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import NIOTransportServices

private enum SSHClientInternalError: Error, Sendable {
    case alreadyStarted
    case closed
    case credentialUnavailable
    case unexpectedChildChannel
}

final class SSHClient: SSHClientTransport, @unchecked Sendable {
    private struct ResourceState {
        var group: NIOTSEventLoopGroup?
        var parentChannel: Channel?
        var childChannel: Channel?
        var started = false
        var shutdownStarted = false
        var shutdownComplete = false
        var failure: SSHClientFailure?
        var completions: [@Sendable () -> Void] = []
        var terminalDimensions: SSHTerminalDimensions = .fallback
    }

    private struct ShutdownSnapshot {
        let group: NIOTSEventLoopGroup?
        let parentChannel: Channel?
        let childChannel: Channel?
    }

    private let host: SSHHost
    private let callbacks: SSHClientCallbacks
    private let credential: NIOLockedValueBox<SSHClientCredential?>
    private let hostKeyValidator: SSHHostKeyValidator
    private let resources: NIOLockedValueBox<ResourceState>

    init(configuration: LiteTermSSHClientConfiguration) {
        host = configuration.host
        callbacks = configuration.callbacks
        credential = NIOLockedValueBox(configuration.credential)
        var initialResources = ResourceState()
        initialResources.terminalDimensions = configuration.terminalDimensions
        resources = NIOLockedValueBox(initialResources)
        hostKeyValidator = SSHHostKeyValidator(
            trustedFingerprint: configuration.trustedFingerprint,
            onTrustRequired: configuration.callbacks.hostTrustRequired,
            onValidated: configuration.callbacks.hostKeyValidated
        )
    }

    func connect() {
        let group: NIOTSEventLoopGroup? = resources.withLockedValue { state in
            guard !state.started, !state.shutdownStarted else { return nil }
            state.started = true
            let group = NIOTSEventLoopGroup(loopCount: 1)
            state.group = group
            return group
        }
        guard let group else {
            fail(SSHClientInternalError.alreadyStarted)
            return
        }

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { [weak self] channel in
                guard let self, self.registerParentChannel(channel) else {
                    return channel.eventLoop.makeFailedFuture(SSHClientInternalError.closed)
                }
                return channel.eventLoop.makeCompletedFuture {
                    guard let credential = self.takeCredential() else {
                        throw SSHClientInternalError.credentialUnavailable
                    }
                    let authenticationDelegate = SSHAuthenticationDelegate(
                        username: self.host.username,
                        credential: credential
                    )
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            SSHClientConfiguration(
                                userAuthDelegate: authenticationDelegate,
                                serverAuthDelegate: self.hostKeyValidator
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    let parentHandler = SSHParentEventHandler(
                        sshHandler: sshHandler,
                        client: self
                    )
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(sshHandler)
                    try pipeline.addHandler(parentHandler)
                }
            }

        bootstrap.connect(
            host: host.hostname,
            port: host.port
        ).whenFailure { [weak self] error in
            self?.fail(error)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let channel = activeChildChannel() else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenFailure { [weak self] error in
            self?.fail(error)
        }
    }

    func resize(columns: Int, rows: Int) {
        let dimensions = SSHTerminalDimensions(columns: columns, rows: rows)
        let channel = resources.withLockedValue { state -> Channel? in
            state.terminalDimensions = dimensions
            guard !state.shutdownStarted else { return nil }
            return state.childChannel
        }
        guard let channel else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: dimensions.columns,
            terminalRowHeight: dimensions.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { [weak self] error in
            self?.fail(error)
        }
        channel.pipeline.triggerUserOutboundEvent(request, promise: promise)
    }

    func confirmHostTrust() {
        hostKeyValidator.confirmPendingTrust()
    }

    func rejectHostTrust(as failure: SSHClientFailure) {
        hostKeyValidator.rejectPendingTrust(as: failure)
        beginShutdown(failure: failure, completion: nil)
    }

    func close(completion: @escaping @Sendable () -> Void) {
        beginShutdown(failure: nil, completion: completion)
    }

    fileprivate func authenticated(using sshHandler: NIOSSHHandler, on channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
            guard let self else {
                return childChannel.eventLoop.makeFailedFuture(SSHClientInternalError.closed)
            }
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(SSHClientInternalError.unexpectedChildChannel)
            }
            guard self.registerChildChannel(childChannel) else {
                return childChannel.eventLoop.makeFailedFuture(SSHClientInternalError.closed)
            }

            let terminalHandler = SSHTerminalHandler(
                dimensions: self.currentTerminalDimensions(),
                onReady: { [weak self] in
                    self?.callbacks.terminalReady()
                },
                onBytes: { [weak self] bytes in
                    self?.callbacks.receiveBytes(bytes)
                },
                onError: { [weak self] error in
                    self?.fail(error)
                },
                onClosed: { [weak self] in
                    self?.beginShutdown(failure: .transport, completion: nil)
                }
            )
            return childChannel.pipeline.addHandler(terminalHandler)
        }
        promise.futureResult.whenFailure { [weak self] error in
            self?.fail(error)
        }
    }

    fileprivate func parentClosed() {
        beginShutdown(failure: .transport, completion: nil)
    }

    fileprivate func fail(_ error: Error) {
        beginShutdown(failure: Self.failureCategory(for: error), completion: nil)
    }

    private func registerParentChannel(_ channel: Channel) -> Bool {
        resources.withLockedValue { state in
            guard !state.shutdownStarted else { return false }
            state.parentChannel = channel
            return true
        }
    }

    private func registerChildChannel(_ channel: Channel) -> Bool {
        resources.withLockedValue { state in
            guard !state.shutdownStarted else { return false }
            state.childChannel = channel
            return true
        }
    }

    private func activeChildChannel() -> Channel? {
        resources.withLockedValue { state in
            guard !state.shutdownStarted else { return nil }
            return state.childChannel
        }
    }

    private func currentTerminalDimensions() -> SSHTerminalDimensions {
        resources.withLockedValue { $0.terminalDimensions }
    }

    private func beginShutdown(
        failure: SSHClientFailure?,
        completion: (@Sendable () -> Void)?
    ) {
        var immediateCompletion: (@Sendable () -> Void)?
        let snapshot: ShutdownSnapshot? = resources.withLockedValue { state in
            if let failure,
               state.failure == nil || (state.failure == .transport && failure != .transport) {
                state.failure = failure
            }
            if let completion {
                if state.shutdownComplete {
                    immediateCompletion = completion
                } else {
                    state.completions.append(completion)
                }
            }
            guard !state.shutdownStarted else { return nil }
            state.shutdownStarted = true
            return ShutdownSnapshot(
                group: state.group,
                parentChannel: state.parentChannel,
                childChannel: state.childChannel
            )
        }

        if let immediateCompletion {
            immediateCompletion()
        }
        guard let snapshot else { return }
        credential.withLockedValue { $0 = nil }
        hostKeyValidator.cancelPendingValidation()
        close(snapshot) { [self] in
            let final = resources.withLockedValue { state -> (SSHClientFailure?, [@Sendable () -> Void]) in
                state.shutdownComplete = true
                let result = (state.failure, state.completions)
                state.completions.removeAll(keepingCapacity: false)
                state.parentChannel = nil
                state.childChannel = nil
                state.group = nil
                return result
            }
            if let failure = final.0 {
                callbacks.connectionClosed(failure)
            }
            final.1.forEach { $0() }
        }
    }

    private func close(_ snapshot: ShutdownSnapshot, completion: @escaping @Sendable () -> Void) {
        let shutdownGroup: @Sendable () -> Void = {
            guard let group = snapshot.group else {
                completion()
                return
            }
            group.shutdownGracefully(queue: .global(qos: .utility)) { _ in
                completion()
            }
        }

        let closeParent: @Sendable () -> Void = {
            guard let parent = snapshot.parentChannel else {
                shutdownGroup()
                return
            }
            parent.close().whenComplete { _ in
                shutdownGroup()
            }
        }

        guard let child = snapshot.childChannel else {
            closeParent()
            return
        }
        child.close().whenComplete { _ in
            closeParent()
        }
    }

    private func takeCredential() -> SSHClientCredential? {
        credential.withLockedValue { credential in
            defer { credential = nil }
            return credential
        }
    }

    private static func failureCategory(for error: Error) -> SSHClientFailure {
        if error is SSHAuthenticationDelegateError {
            return .authenticationRejected
        }
        if let validationError = error as? SSHHostKeyValidationError {
            switch validationError {
            case .hostKeyMismatch:
                return .hostKeyMismatch
            case .credentialUnavailable:
                return .credentialUnavailable
            case .trustCancelled, .validationSuperseded:
                return .trustCancelled
            case .invalidPublicKeyRepresentation:
                return .protocolFailure
            }
        }
        if let internalError = error as? SSHClientInternalError {
            if case .credentialUnavailable = internalError {
                return .credentialUnavailable
            }
            return .protocolFailure
        }
        if error is SSHTerminalHandlerError {
            return .protocolFailure
        }
        if let sshError = error as? NIOSSHError, sshError.type != .tcpShutdown {
            return .protocolFailure
        }
        return .transport
    }
}

private final class SSHParentEventHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let sshHandler: NIOSSHHandler
    private weak var client: SSHClient?

    init(sshHandler: NIOSSHHandler, client: SSHClient) {
        self.sshHandler = sshHandler
        self.client = client
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            client?.authenticated(using: sshHandler, on: context.channel)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client?.fail(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        client?.parentClosed()
        context.fireChannelInactive()
    }
}
