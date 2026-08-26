import Crypto
import Foundation
import LiteSpaceCore
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH

enum SSHIntegrationTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

enum LiteSpaceSSHIntegrationTestRunner {
    static func run() throws {
        try childChannelEnablesRemoteHalfClosure()
        try passwordHostKeyPTYIOResizeAndRemoteEOF()
        print("PASS: LiteSpace SSH integration checks")
    }

    private static func childChannelEnablesRemoteHalfClosure() throws {
        let handler = SSHTerminalHandler(
            dimensions: .fallback,
            onReady: {},
            onBytes: { _, acknowledge in acknowledge() },
            onError: { _ in },
            onClosed: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }

        let allowsRemoteHalfClosure = try channel.getOption(
            ChannelOptions.allowRemoteHalfClosure
        ).wait()
        guard allowsRemoteHalfClosure else {
            throw SSHIntegrationTestFailure.assertion(
                "SSH child channel must enable remote half closure"
            )
        }
    }

    private static func passwordHostKeyPTYIOResizeAndRemoteEOF() throws {
        let server = try LoopbackSSHServer(username: "litespace", password: "test-password")
        defer { server.shutdown() }

        let host = try SSHHost(
            label: "Loopback",
            hostname: "127.0.0.1",
            port: server.port,
            username: "litespace",
            authenticationKind: .password,
            reconnectPreference: .disabled
        )
        let clientEvents = LoopbackClientEvents()
        let client = SSHClient(
            configuration: LiteSpaceSSHClientConfiguration(
                host: host,
                credential: .password("test-password"),
                storedFingerprint: .absent,
                terminalDimensions: SSHTerminalDimensions(columns: 91, rows: 37),
                callbacks: SSHClientCallbacks(
                    hostTrustRequired: clientEvents.recordTrust,
                    hostKeyValidated: clientEvents.recordHostKeyValidated,
                    terminalReady: clientEvents.recordReady,
                    receiveBytes: clientEvents.recordBytes,
                    connectionClosed: clientEvents.recordFailure
                )
            )
        )
        defer {
            let closed = DispatchSemaphore(value: 0)
            client.close { closed.signal() }
            _ = closed.wait(timeout: .now() + 5)
        }

        client.connect()
        try eventually("first-use host key prompt") {
            clientEvents.trustKind == .firstUse
                && clientEvents.fingerprint?.hasPrefix("SHA256:") == true
        }
        client.confirmHostTrust()
        try eventually("validated host key") { clientEvents.hostKeyValidated }
        try eventually("password authentication") { server.passwordAuthenticated }
        try eventually("interactive PTY readiness") { clientEvents.isReady }
        try require(
            server.initialPTY == LoopbackTerminalSize(columns: 91, rows: 37),
            "loopback server must receive the initial PTY dimensions"
        )
        try require(server.terminalType == "xterm-256color", "PTY type must be xterm-256color")
        try require(server.didRequestShell, "client must request an interactive shell")

        client.send(Array("ping\r".utf8))
        try eventually("server input") { server.receivedBytes == Array("ping\r".utf8) }
        try eventually("client output") {
            clientEvents.receivedBytes.containsSubsequence(Array("pong\r\n".utf8))
        }

        client.resize(columns: 132, rows: 43)
        try eventually("PTY resize") {
            server.latestWindow == LoopbackTerminalSize(columns: 132, rows: 43)
        }

        try server.sendOutputAndEOF(Array("bye\r\n".utf8))
        try eventually("final output before remote EOF") {
            clientEvents.receivedBytes.containsSubsequence(Array("bye\r\n".utf8))
        }
        try eventually("remote EOF closes the client session") {
            clientEvents.failureCount > 0
        }
        try require(
            clientEvents.lastFailureDescription == "remoteSessionEnded",
            "remote shell EOF must not be classified as a transport failure"
        )
    }
}

private struct LoopbackTerminalSize: Equatable {
    let columns: Int
    let rows: Int
}

private final class LoopbackPasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    private let username: String
    private let password: String
    private let recorder: LoopbackServerRecorder

    init(username: String, password: String, recorder: LoopbackServerRecorder) {
        self.username = username
        self.password = password
        self.recorder = recorder
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard
            request.username == username,
            case .password(let passwordRequest) = request.request,
            passwordRequest.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        recorder.recordPasswordAuthentication()
        responsePromise.succeed(.success)
    }
}

private final class LoopbackServerRecorder: @unchecked Sendable {
    private struct State {
        var passwordAuthenticated = false
        var terminalType: String?
        var initialPTY: LoopbackTerminalSize?
        var latestWindow: LoopbackTerminalSize?
        var didRequestShell = false
        var receivedBytes: [UInt8] = []
        var childChannel: Channel?
    }

    private let state = NIOLockedValueBox(State())

    var passwordAuthenticated: Bool { state.withLockedValue { $0.passwordAuthenticated } }
    var terminalType: String? { state.withLockedValue { $0.terminalType } }
    var initialPTY: LoopbackTerminalSize? { state.withLockedValue { $0.initialPTY } }
    var latestWindow: LoopbackTerminalSize? { state.withLockedValue { $0.latestWindow } }
    var didRequestShell: Bool { state.withLockedValue { $0.didRequestShell } }
    var receivedBytes: [UInt8] { state.withLockedValue { $0.receivedBytes } }

    func recordPasswordAuthentication() {
        state.withLockedValue { $0.passwordAuthenticated = true }
    }

    func recordChildChannel(_ channel: Channel) {
        state.withLockedValue { $0.childChannel = channel }
    }

    func recordPTY(_ request: SSHChannelRequestEvent.PseudoTerminalRequest) {
        state.withLockedValue { state in
            state.terminalType = request.term
            state.initialPTY = LoopbackTerminalSize(
                columns: request.terminalCharacterWidth,
                rows: request.terminalRowHeight
            )
        }
    }

    func recordShellRequest() {
        state.withLockedValue { $0.didRequestShell = true }
    }

    func recordWindow(_ request: SSHChannelRequestEvent.WindowChangeRequest) {
        state.withLockedValue { state in
            state.latestWindow = LoopbackTerminalSize(
                columns: request.terminalCharacterWidth,
                rows: request.terminalRowHeight
            )
        }
    }

    func recordInput(_ bytes: [UInt8]) {
        state.withLockedValue { $0.receivedBytes.append(contentsOf: bytes) }
    }

    func sendOutputAndEOF(_ bytes: [UInt8]) throws {
        guard let channel = state.withLockedValue({ $0.childChannel }) else {
            throw SSHIntegrationTestFailure.assertion("loopback SSH child channel is unavailable")
        }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try channel.writeAndFlush(buffer).flatMap {
            channel.close(mode: .output)
        }.wait()
    }
}

private final class LoopbackShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let recorder: LoopbackServerRecorder
    private var sentPong = false

    init(recorder: LoopbackServerRecorder) {
        self.recorder = recorder
    }

    func handlerAdded(context: ChannelHandlerContext) {
        recorder.recordChildChannel(context.channel)
        context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        ).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            recorder.recordPTY(request)
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let request as SSHChannelRequestEvent.ShellRequest:
            recorder.recordShellRequest()
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            recorder.recordWindow(request)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .channel = channelData.type, case .byteBuffer(var buffer) = channelData.data else {
            context.fireErrorCaught(
                SSHIntegrationTestFailure.assertion("unexpected loopback SSH channel data")
            )
            return
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        recorder.recordInput(bytes)
        guard !sentPong, recorder.receivedBytes.containsSubsequence(Array("ping\r".utf8)) else {
            return
        }
        sentPong = true
        var response = context.channel.allocator.buffer(capacity: 6)
        response.writeString("pong\r\n")
        context.writeAndFlush(wrapOutboundOut(
            SSHChannelData(type: .channel, data: .byteBuffer(response))
        ), promise: nil)
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}

private final class LoopbackServerErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class LoopbackSSHServer {
    private let group: MultiThreadedEventLoopGroup
    private let listeningChannel: Channel
    private let recorder: LoopbackServerRecorder

    var port: Int { listeningChannel.localAddress?.port ?? 0 }
    var passwordAuthenticated: Bool { recorder.passwordAuthenticated }
    var terminalType: String? { recorder.terminalType }
    var initialPTY: LoopbackTerminalSize? { recorder.initialPTY }
    var latestWindow: LoopbackTerminalSize? { recorder.latestWindow }
    var didRequestShell: Bool { recorder.didRequestShell }
    var receivedBytes: [UInt8] { recorder.receivedBytes }

    init(username: String, password: String) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        recorder = LoopbackServerRecorder()
        let authentication = LoopbackPasswordDelegate(
            username: username,
            password: password,
            recorder: recorder
        )
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let recorder = recorder
        listeningChannel = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .server(
                        SSHServerConfiguration(
                            hostKeys: [hostKey],
                            userAuthDelegate: authentication
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(
                                SSHIntegrationTestFailure.assertion(
                                    "loopback server accepts only SSH session channels"
                                )
                            )
                        }
                        return childChannel.eventLoop.makeCompletedFuture {
                            try childChannel.pipeline.syncOperations.addHandler(
                                LoopbackShellHandler(recorder: recorder)
                            )
                        }
                    }
                )
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        sshHandler,
                        LoopbackServerErrorHandler()
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        try require(port > 0, "loopback SSH server must bind an ephemeral port")
    }

    func sendOutputAndEOF(_ bytes: [UInt8]) throws {
        try recorder.sendOutputAndEOF(bytes)
    }

    func shutdown() {
        try? listeningChannel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class LoopbackClientEvents: @unchecked Sendable {
    private struct State {
        var fingerprint: String?
        var trustKind: SSHHostTrustKind?
        var hostKeyValidated = false
        var isReady = false
        var receivedBytes: [UInt8] = []
        var failures: [SSHClientFailure] = []
    }

    private let state = NIOLockedValueBox(State())

    var fingerprint: String? { state.withLockedValue { $0.fingerprint } }
    var trustKind: SSHHostTrustKind? { state.withLockedValue { $0.trustKind } }
    var hostKeyValidated: Bool { state.withLockedValue { $0.hostKeyValidated } }
    var isReady: Bool { state.withLockedValue { $0.isReady } }
    var receivedBytes: [UInt8] { state.withLockedValue { $0.receivedBytes } }
    var failureCount: Int { state.withLockedValue { $0.failures.count } }
    var lastFailureDescription: String? {
        state.withLockedValue { $0.failures.last.map(String.init(describing:)) }
    }

    func recordTrust(_ fingerprint: String, kind: SSHHostTrustKind) {
        state.withLockedValue { state in
            state.fingerprint = fingerprint
            state.trustKind = kind
        }
    }

    func recordHostKeyValidated() {
        state.withLockedValue { $0.hostKeyValidated = true }
    }

    func recordReady() {
        state.withLockedValue { $0.isReady = true }
    }

    func recordBytes(_ bytes: [UInt8], acknowledge: @escaping @Sendable () -> Void) {
        state.withLockedValue { $0.receivedBytes.append(contentsOf: bytes) }
        acknowledge()
    }

    func recordFailure(_ failure: SSHClientFailure) {
        state.withLockedValue { $0.failures.append(failure) }
    }
}

private func eventually(
    _ description: String,
    timeout: TimeInterval = 5,
    condition: () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw SSHIntegrationTestFailure.assertion("Timed out waiting for \(description)")
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw SSHIntegrationTestFailure.assertion(message)
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence {
                return true
            }
        }
        return false
    }
}

try LiteSpaceSSHIntegrationTestRunner.run()
