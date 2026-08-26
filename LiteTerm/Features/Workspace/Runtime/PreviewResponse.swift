import Foundation
import NIOCore

public struct PreviewResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct PreviewResponseSource: @unchecked Sendable {
    public typealias Responder = @Sendable (
        _ request: PreviewRequest,
        _ eventLoop: any EventLoop
    ) -> EventLoopFuture<PreviewResponse>

    private let responder: Responder

    public init(responder: @escaping Responder) {
        self.responder = responder
    }

    func response(
        for request: PreviewRequest,
        on eventLoop: any EventLoop
    ) -> EventLoopFuture<PreviewResponse> {
        responder(request, eventLoop)
    }

    public static func staticFiles(_ files: [String: PreviewResponse]) -> PreviewResponseSource {
        PreviewResponseSource { request, eventLoop in
            guard request.method == "GET" || request.method == "HEAD" else {
                return eventLoop.makeSucceededFuture(
                    PreviewResponse(status: 405, headers: [:], body: Data())
                )
            }
            guard let response = files[request.relativePath] else {
                return eventLoop.makeSucceededFuture(
                    PreviewResponse(status: 404, headers: [:], body: Data())
                )
            }
            return eventLoop.makeSucceededFuture(response)
        }
    }
}
