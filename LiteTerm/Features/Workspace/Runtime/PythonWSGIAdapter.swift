import Foundation
import NIOCore

public enum PythonWSGIAdapterError: Error, Equatable, Sendable {
    case invalidMethod
    case invalidPath
    case invalidQuery
    case requestTooLarge
    case invalidStatus
    case invalidHeader
    case responseTooLarge
}

public struct PythonHTTPRequestEnvelope: Equatable, Sendable {
    public let method: String
    public let pathInfo: String
    public let queryString: String
    public let environ: [String: String]
    public let body: Data
}

public struct PythonWSGIHeader: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct PythonWSGIResponseEnvelope: Equatable, Sendable {
    public let status: String
    public let headers: [PythonWSGIHeader]
    public let body: Data

    public init(status: String, headers: [PythonWSGIHeader], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum PythonWSGIAdapter {
    public static let maximumRequestBytes = 256 * 1_024
    public static let maximumResponseBytes = 5 * 1_024 * 1_024
    public static let maximumHeaderCount = 64

    public typealias Application = @Sendable (
        PythonHTTPRequestEnvelope
    ) async throws -> PythonWSGIResponseEnvelope

    public static func makeRequest(from request: PreviewRequest) throws -> PythonHTTPRequestEnvelope {
        guard ["GET", "HEAD", "POST"].contains(request.method) else {
            throw PythonWSGIAdapterError.invalidMethod
        }
        do {
            try PreviewPathPolicy.validate(request.relativePath, allowEmpty: true)
        } catch {
            throw PythonWSGIAdapterError.invalidPath
        }
        guard request.body.count <= maximumRequestBytes else {
            throw PythonWSGIAdapterError.requestTooLarge
        }
        let query = request.query ?? ""
        guard query.utf8.count <= 4_096,
              !query.contains("\0"), !query.contains("\r"), !query.contains("\n") else {
            throw PythonWSGIAdapterError.invalidQuery
        }

        var environ = [
            "REQUEST_METHOD": request.method,
            "SCRIPT_NAME": "",
            "PATH_INFO": request.relativePath.isEmpty ? "/" : "/\(request.relativePath)",
            "QUERY_STRING": query,
            "SERVER_NAME": "localhost",
            "SERVER_PROTOCOL": "HTTP/1.1",
            "wsgi.url_scheme": "http",
            "wsgi.version": "1.0",
            "wsgi.multithread": "false",
            "wsgi.multiprocess": "false",
            "wsgi.run_once": "false"
        ]
        if let contentType = request.headers["Content-Type"],
           contentType.utf8.count <= 1_024,
           !contentType.contains("\r"), !contentType.contains("\n") {
            environ["CONTENT_TYPE"] = contentType
        }
        environ["CONTENT_LENGTH"] = "\(request.body.count)"

        return PythonHTTPRequestEnvelope(
            method: request.method,
            pathInfo: request.relativePath.isEmpty ? "/" : "/\(request.relativePath)",
            queryString: query,
            environ: environ,
            body: request.body
        )
    }

    public static func makePreviewResponse(
        from response: PythonWSGIResponseEnvelope
    ) throws -> PreviewResponse {
        guard let status = statusCode(from: response.status) else {
            throw PythonWSGIAdapterError.invalidStatus
        }
        guard response.body.count <= maximumResponseBytes else {
            throw PythonWSGIAdapterError.responseTooLarge
        }
        guard response.headers.count <= maximumHeaderCount else {
            throw PythonWSGIAdapterError.invalidHeader
        }

        let omittedHeaders: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade", "content-length", "set-cookie"
        ]
        var approvedHeaders: [String: String] = [:]
        for header in response.headers {
            let lowercaseName = header.name.lowercased()
            guard isHeaderName(header.name),
                  header.value.utf8.count <= 4_096,
                  !header.value.contains("\r"), !header.value.contains("\n") else {
                throw PythonWSGIAdapterError.invalidHeader
            }
            guard !omittedHeaders.contains(lowercaseName) else { continue }
            approvedHeaders[header.name] = header.value
        }
        return PreviewResponse(status: status, headers: approvedHeaders, body: response.body)
    }

    public static func previewSource(application: @escaping Application) -> PreviewResponseSource {
        PreviewResponseSource { request, eventLoop in
            eventLoop.makeFutureWithTask {
                do {
                    let envelope = try makeRequest(from: request)
                    let response = try await application(envelope)
                    return try makePreviewResponse(from: response)
                } catch {
                    return PreviewResponse(status: 500, headers: [:], body: Data())
                }
            }
        }
    }

    private static func statusCode(from value: String) -> Int? {
        guard value.utf8.count <= 128,
              !value.contains("\r"), !value.contains("\n"),
              value.count >= 5 else { return nil }
        let characters = Array(value)
        guard characters[3] == " ",
              characters[0...2].allSatisfy(\.isNumber),
              let status = Int(String(characters[0...2])),
              (200...599).contains(status) else { return nil }
        return status
    }

    private static func isHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return value.utf8.allSatisfy { byte in
            byte < 128 && (
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || allowedPunctuation.contains(byte)
            )
        }
    }
}
