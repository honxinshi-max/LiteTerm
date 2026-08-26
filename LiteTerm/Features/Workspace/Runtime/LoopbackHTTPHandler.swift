import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

final class LoopbackServerContext: @unchecked Sendable {
    let generation: UInt64
    let secretHex: String
    let source: PreviewResponseSource
    private let boundPortBox = NIOLockedValueBox<Int>(0)

    init(generation: UInt64, secretHex: String, source: PreviewResponseSource) {
        self.generation = generation
        self.secretHex = secretHex
        self.source = source
    }

    var boundPort: Int { boundPortBox.withLockedValue { $0 } }

    func setBoundPort(_ port: Int) {
        boundPortBox.withLockedValue { $0 = port }
    }

    func authenticatedRequest(
        head: HTTPRequestHead,
        body: Data
    ) throws -> (PreviewRequest, bootstrap: Bool) {
        guard body.count <= 256 * 1_024 else {
            throw PreviewRuntimeError.requestTooLarge
        }
        guard head.uri.count <= 8_192, !head.uri.contains("#") else {
            throw PreviewRuntimeError.invalidRequest
        }
        guard head.headers.count <= 64 else {
            throw PreviewRuntimeError.invalidRequest
        }
        let expectedHost = "127.0.0.1:\(boundPort)"
        guard head.headers.first(name: "Host")?.lowercased() == expectedHost else {
            throw PreviewRuntimeError.invalidRequest
        }

        let uriParts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawPath = uriParts.first, rawPath.hasPrefix("/") else {
            throw PreviewRuntimeError.invalidPath
        }
        guard let decodedPath = String(rawPath).removingPercentEncoding else {
            throw PreviewRuntimeError.invalidPath
        }
        let query = uriParts.count == 2 ? String(uriParts[1]) : nil
        let bootstrapPrefix = "/__liteterm/\(secretHex)/"
        let bootstrap = decodedPath.hasPrefix(bootstrapPrefix)
        let headerAuthenticated = head.headers.first(name: "X-LiteTerm-Run") == secretHex
        let cookieAuthenticated = head.headers["Cookie"].contains { value in
            value.split(separator: ";").contains { part in
                part.trimmingCharacters(in: .whitespaces) == "LiteTermRun=\(secretHex)"
            }
        }
        guard bootstrap || headerAuthenticated || cookieAuthenticated else {
            throw PreviewRuntimeError.unavailable
        }

        let relativePath: String
        if bootstrap {
            relativePath = String(decodedPath.dropFirst(bootstrapPrefix.count))
        } else {
            relativePath = String(decodedPath.dropFirst())
        }
        try PreviewPathPolicy.validate(relativePath, allowEmpty: true)

        var approvedHeaders: [String: String] = [:]
        for name in ["Accept", "Accept-Language", "Content-Type", "Content-Length", "User-Agent"] {
            if let value = head.headers.first(name: name), value.utf8.count <= 1_024 {
                approvedHeaders[name] = value
            }
        }
        return (
            PreviewRequest(
                method: head.method.rawValue,
                relativePath: relativePath,
                query: query,
                headers: approvedHeaders,
                body: body
            ),
            bootstrap
        )
    }
}

final class LoopbackHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let serverContext: LoopbackServerContext
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var requestExceededLimit = false

    init(serverContext: LoopbackServerContext) {
        self.serverContext = serverContext
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
            requestBody.removeAll(keepingCapacity: true)
            requestExceededLimit = false
        case var .body(buffer):
            guard !requestExceededLimit else { return }
            if requestBody.count + buffer.readableBytes > 256 * 1_024 {
                requestExceededLimit = true
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            respond(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func respond(context: ChannelHandlerContext) {
        let isHealthRequest = requestHead?.headers.first(name: "X-LiteTerm-Health") == "1"
        guard let head = requestHead, !requestExceededLimit else {
            write(
                PreviewResponse(status: 413, headers: [:], body: Data()),
                bootstrap: false,
                requestMethod: requestHead?.method,
                isHealthRequest: isHealthRequest,
                context: context
            )
            return
        }

        do {
            let authenticated = try serverContext.authenticatedRequest(head: head, body: requestBody)
            let contextBox = LoopbackUncheckedSendable(value: context)
            serverContext.source.response(for: authenticated.0, on: context.eventLoop).whenComplete {
                [weak self, contextBox] result in
                guard let self else { return }
                let context = contextBox.value
                let response: PreviewResponse
                switch result {
                case let .success(value):
                    response = value
                case .failure:
                    response = PreviewResponse(status: 500, headers: [:], body: Data())
                }
                self.write(
                    response,
                    bootstrap: authenticated.bootstrap,
                    requestMethod: head.method,
                    isHealthRequest: isHealthRequest,
                    context: context
                )
            }
        } catch PreviewRuntimeError.requestTooLarge {
            write(
                PreviewResponse(status: 413, headers: [:], body: Data()),
                bootstrap: false,
                requestMethod: head.method,
                isHealthRequest: isHealthRequest,
                context: context
            )
        } catch {
            write(
                PreviewResponse(status: 404, headers: [:], body: Data()),
                bootstrap: false,
                requestMethod: head.method,
                isHealthRequest: isHealthRequest,
                context: context
            )
        }
    }

    private func write(
        _ previewResponse: PreviewResponse,
        bootstrap: Bool,
        requestMethod: HTTPMethod?,
        isHealthRequest: Bool,
        context: ChannelHandlerContext
    ) {
        let boundedResponse: PreviewResponse
        if isHealthRequest && previewResponse.body.count > 256 * 1_024 {
            boundedResponse = PreviewResponse(status: 413, headers: [:], body: Data())
        } else if previewResponse.body.count > 5 * 1_024 * 1_024
            || !(200...599).contains(previewResponse.status) {
            boundedResponse = PreviewResponse(status: 500, headers: [:], body: Data())
        } else {
            boundedResponse = previewResponse
        }

        var headers = HTTPHeaders()
        for (name, value) in boundedResponse.headers.sorted(by: { $0.key < $1.key }) {
            guard
                name.utf8.count <= 128,
                value.utf8.count <= 4_096,
                !name.contains("\r"),
                !name.contains("\n"),
                !value.contains("\r"),
                !value.contains("\n"),
                name.lowercased() != "set-cookie",
                name.lowercased() != "connection",
                name.lowercased() != "content-length"
            else {
                continue
            }
            headers.add(name: name, value: value)
        }
        if bootstrap {
            headers.add(
                name: "Set-Cookie",
                value: "LiteTermRun=\(serverContext.secretHex); Path=/; HttpOnly; SameSite=Strict"
            )
        }
        let body = requestMethod == .HEAD ? Data() : boundedResponse.body
        headers.replaceOrAdd(name: "Content-Length", value: "\(body.count)")
        headers.replaceOrAdd(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: boundedResponse.status),
            headers: headers
        )
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

private struct LoopbackUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
