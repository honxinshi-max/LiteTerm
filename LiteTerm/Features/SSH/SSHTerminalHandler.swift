import NIOCore
import NIOSSH

enum SSHTerminalHandlerError: Error, Sendable {
    case channelRequestRejected
    case unsupportedChannelData
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
    private let onBytes: @Sendable ([UInt8]) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onClosed: @Sendable () -> Void
    private var setupPhase = SetupPhase.idle

    init(
        dimensions: SSHTerminalDimensions,
        onReady: @escaping @Sendable () -> Void,
        onBytes: @escaping @Sendable ([UInt8]) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.dimensions = dimensions
        self.onReady = onReady
        self.onBytes = onBytes
        self.onError = onError
        self.onClosed = onClosed
    }

    func channelActive(context: ChannelHandlerContext) {
        setupPhase = .awaitingPTYReply
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: dimensions.columns,
            terminalRowHeight: dimensions.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
        trigger(request, context: context)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch (setupPhase, event) {
        case (.awaitingPTYReply, is ChannelSuccessEvent):
            setupPhase = .awaitingShellReply
            trigger(SSHChannelRequestEvent.ShellRequest(wantReply: true), context: context)

        case (.awaitingShellReply, is ChannelSuccessEvent):
            setupPhase = .ready
            onReady()

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
        onBytes(Array(buffer.readableBytesView))
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
