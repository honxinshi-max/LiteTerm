import NIOCore
import NIOSSH

enum SSHTerminalHandlerError: Error, Sendable {
    case channelRequestRejected
    case unsupportedChannelData
    case outputBackpressureOverflow
}

struct SSHChildSessionCreationGate {
    private var isClaimed = false

    mutating func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

struct SSHOutputDeliveryGate {
    enum Admission: Equatable {
        case accepted(UInt64)
        case overflow
    }

    let maximumChunkBytes: Int
    private(set) var inFlightToken: UInt64?
    private var nextToken: UInt64 = 0

    init(maximumChunkBytes: Int) {
        precondition(maximumChunkBytes > 0, "SSH output bound must be positive")
        self.maximumChunkBytes = maximumChunkBytes
    }

    mutating func admit(byteCount: Int) -> Admission {
        guard byteCount >= 0, byteCount <= maximumChunkBytes, inFlightToken == nil else {
            return .overflow
        }
        precondition(nextToken < UInt64.max, "SSH output delivery token exhausted")
        nextToken += 1
        inFlightToken = nextToken
        return .accepted(nextToken)
    }

    mutating func acknowledge(token: UInt64) -> Bool {
        guard inFlightToken == token else { return false }
        inFlightToken = nil
        return true
    }

    var hasInFlightDelivery: Bool {
        inFlightToken != nil
    }
}

final class SSHTerminalHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private enum SetupPhase {
        case idle
        case awaitingPTYReply
        case awaitingShellReply
        case ready
    }

    private let dimensions: SSHTerminalDimensions
    private let onReady: @Sendable () -> Void
    private let onBytes: @Sendable (
        [UInt8],
        @escaping @Sendable () -> Void
    ) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onClosed: @Sendable () -> Void
    private var setupPhase = SetupPhase.idle
    private var outputDeliveryGate: SSHOutputDeliveryGate

    init(
        dimensions: SSHTerminalDimensions,
        maximumOutputChunkBytes: Int = 64 * 1024,
        onReady: @escaping @Sendable () -> Void,
        onBytes: @escaping @Sendable (
            [UInt8],
            @escaping @Sendable () -> Void
        ) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.dimensions = dimensions
        outputDeliveryGate = SSHOutputDeliveryGate(
            maximumChunkBytes: maximumOutputChunkBytes
        )
        self.onReady = onReady
        self.onBytes = onBytes
        self.onError = onError
        self.onClosed = onClosed
    }

    func channelActive(context: ChannelHandlerContext) {
        setupPhase = .awaitingPTYReply
        trigger(Self.pseudoTerminalRequest(dimensions: dimensions), context: context)
        context.read()
        context.fireChannelActive()
    }

    static func pseudoTerminalRequest(
        dimensions: SSHTerminalDimensions
    ) -> SSHChannelRequestEvent.PseudoTerminalRequest {
        SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: dimensions.columns,
            terminalRowHeight: dimensions.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch (setupPhase, event) {
        case (.awaitingPTYReply, is ChannelSuccessEvent):
            setupPhase = .awaitingShellReply
            trigger(SSHChannelRequestEvent.ShellRequest(wantReply: true), context: context)
            context.read()

        case (.awaitingShellReply, is ChannelSuccessEvent):
            setupPhase = .ready
            onReady()
            context.read()

        case (_, is ChannelFailureEvent):
            fail(SSHTerminalHandlerError.channelRequestRejected, context: context)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else {
            fail(SSHTerminalHandlerError.unsupportedChannelData, context: context)
            return
        }
        guard case .accepted(let token) = outputDeliveryGate.admit(
            byteCount: buffer.readableBytes
        ) else {
            fail(SSHTerminalHandlerError.outputBackpressureOverflow, context: context)
            return
        }
        let bytes = Array(buffer.readableBytesView)
        let channel = context.channel
        onBytes(bytes) { [weak self] in
            channel.eventLoop.execute { [weak self] in
                guard
                    let self,
                    self.outputDeliveryGate.acknowledge(token: token),
                    channel.isActive
                else {
                    return
                }
                channel.read()
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        if !outputDeliveryGate.hasInFlightDelivery {
            context.read()
        }
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClosed()
        context.fireChannelInactive()
    }

    private func trigger<Event>(_ event: Event, context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { [onError] error in
            onError(error)
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        onError(error)
        context.close(promise: nil)
    }
}
