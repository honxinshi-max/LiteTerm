import Foundation

public struct PreviewRequest: Equatable, Sendable {
    public let method: String
    public let relativePath: String
    public let query: String?
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        relativePath: String,
        query: String?,
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.relativePath = relativePath
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public enum PreviewRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidPort
    case invalidPath
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case unavailable
    case healthTimedOut
    case unhealthyResponse
}

enum PreviewPathPolicy {
    static func validate(_ relativePath: String, allowEmpty: Bool = false) throws {
        if relativePath.isEmpty {
            guard allowEmpty else { throw PreviewRuntimeError.invalidPath }
            return
        }
        guard
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.contains("\0")
        else {
            throw PreviewRuntimeError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PreviewRuntimeError.invalidPath
        }
        for component in components {
            let lowercase = component.lowercased()
            let filenameParts = lowercase.split(separator: ".", omittingEmptySubsequences: false)
            let stem = filenameParts.first.map(String.init) ?? lowercase
            let fileExtension = filenameParts.count > 1 ? String(filenameParts.last ?? "") : ""
            if lowercase.hasPrefix(".")
                || ["credential", "credentials", "secret", "secrets", "token", "tokens",
                    "private_key", "private-key", "id_rsa", "id_ed25519"].contains(stem)
                || stem.hasPrefix("id_")
                || ["key", "pem", "p12", "pfx", "mobileprovision"].contains(fileExtension) {
                throw PreviewRuntimeError.invalidPath
            }
        }
    }
}
