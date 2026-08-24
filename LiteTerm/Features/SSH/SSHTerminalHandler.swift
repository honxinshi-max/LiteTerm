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

    private struct OutputDelivery {
        let token: UInt64
        let byteCount: Int
    }

    // NIOSSH 0.15.0 advertises a default child receive window of its 128 KiB
    // maximum channel packet size multiplied by 64. One manual read may deliver
    // that entire 8 MiB window before one channelReadComplete, so the pending cap
    // must cover that valid read cycle. MainActor deliveries remain much smaller.
    static let defaultMaximumPendingOutputBytes = 8 * 1024 * 1024
    static let defaultMaximumDeliveryBatchBytes = 64 * 1024

    private let dimensions: SSHTerminalDimensions
    private let onReady: @Sendable () -> Void
    private let onBytes: @Sendable (
        [UInt8],
        @escaping @Sendable () -> Void
    ) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onClosed: @Sendable () -> Void
    private let maximumPendingOutputBytes: Int
    private let maximumDeliveryBatchBytes: Int
    private var setupPhase = SetupPhase.idle
    private var pendingOutput: ByteBuffer?
    private var bufferedUnsanitizedByteCount = 0
    private var outputDeliveryInFlight: OutputDelivery?
    private var nextOutputDeliveryToken: UInt64 = 0
    private var readCycleComplete = false
    private var outputIsClosed = false
    private var didNotifyClosed = false

    init(
        dimensions: SSHTerminalDimensions,
        maximumPendingOutputBytes: Int = defaultMaximumPendingOutputBytes,
        maximumDeliveryBatchBytes: Int = defaultMaximumDeliveryBatchBytes,
        onReady: @escaping @Sendable () -> Void,
        onBytes: @escaping @Sendable (
            [UInt8],
            @escaping @Sendable () -> Void
        ) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        precondition(
            maximumPendingOutputBytes > 0,
            "SSH pending output bound must be positive"
        )
        precondition(
            maximumDeliveryBatchBytes > 0,
            "SSH output delivery batch must be positive"
        )
        precondition(
            maximumDeliveryBatchBytes <= maximumPendingOutputBytes,
            "SSH delivery batch cannot exceed the pending output bound"
        )
        self.dimensions = dimensions
        self.maximumPendingOutputBytes = maximumPendingOutputBytes
        self.maximumDeliveryBatchBytes = maximumDeliveryBatchBytes
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
        let (nextByteCount, overflowed) = bufferedUnsanitizedByteCount
            .addingReportingOverflow(buffer.readableBytes)
        guard
            !outputIsClosed,
            !overflowed,
            nextByteCount <= maximumPendingOutputBytes
        else {
            fail(SSHTerminalHandlerError.outputBackpressureOverflow, context: context)
            return
        }
        bufferedUnsanitizedByteCount = nextByteCount
        guard buffer.readableBytes > 0 else { return }
        if pendingOutput == nil {
            pendingOutput = context.channel.allocator.buffer(
                capacity: buffer.readableBytes
            )
        }
        var source = buffer
        pendingOutput?.writeBuffer(&source)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        guard !outputIsClosed else { return }
        readCycleComplete = true
        advanceOutput(on: context.channel)
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
        clearOutputState()
        outputIsClosed = true
        if !didNotifyClosed {
            didNotifyClosed = true
            onClosed()
        }
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
        guard !outputIsClosed else { return }
        clearOutputState()
        outputIsClosed = true
        onError(error)
        context.close(promise: nil)
    }

    private func advanceOutput(on channel: Channel) {
        guard
            !outputIsClosed,
            outputDeliveryInFlight == nil,
            channel.isActive
        else {
            return
        }

        if var buffer = pendingOutput, buffer.readableBytes > 0 {
            let byteCount = min(buffer.readableBytes, maximumDeliveryBatchBytes)
            guard let bytes = buffer.readBytes(length: byteCount) else {
                preconditionFailure("validated SSH output batch was unavailable")
            }
            pendingOutput = buffer.readableBytes == 0 ? nil : buffer
            precondition(
                nextOutputDeliveryToken < UInt64.max,
                "SSH output delivery token exhausted"
            )
            nextOutputDeliveryToken += 1
            let delivery = OutputDelivery(
                token: nextOutputDeliveryToken,
                byteCount: byteCount
            )
            outputDeliveryInFlight = delivery
            onBytes(bytes) { [weak self] in
                channel.eventLoop.execute { [weak self] in
                    self?.acknowledgeOutput(
                        token: delivery.token,
                        on: channel
                    )
                }
            }
            return
        }

        pendingOutput = nil
        guard readCycleComplete else { return }
        readCycleComplete = false
        channel.read()
    }

    private func acknowledgeOutput(token: UInt64, on channel: Channel) {
        guard
            !outputIsClosed,
            let delivery = outputDeliveryInFlight,
            delivery.token == token,
            channel.isActive
        else {
            return
        }
        outputDeliveryInFlight = nil
        bufferedUnsanitizedByteCount -= delivery.byteCount
        precondition(
            bufferedUnsanitizedByteCount >= 0,
            "SSH output byte accounting underflow"
        )
        advanceOutput(on: channel)
    }

    private func clearOutputState() {
        pendingOutput = nil
        bufferedUnsanitizedByteCount = 0
        outputDeliveryInFlight = nil
        readCycleComplete = false
    }
}
