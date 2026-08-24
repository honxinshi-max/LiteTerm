import Foundation

public enum SSHAuthenticationKind: String, Codable, CaseIterable, Sendable {
    case password
    case generatedKey
}

public enum HostReconnectPreference: String, Codable, CaseIterable, Sendable {
    case enabled
    case disabled
}

public enum SSHHostValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case emptyHostname
    case invalidPort(Int)
    case emptyUsername
}

public struct SSHHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authenticationKind: SSHAuthenticationKind
    public let reconnectPreference: HostReconnectPreference

    public init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authenticationKind: SSHAuthenticationKind,
        reconnectPreference: HostReconnectPreference = .enabled
    ) throws {
        try Self.validate(label: label, hostname: hostname, port: port, username: username)
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authenticationKind = authenticationKind
        self.reconnectPreference = reconnectPreference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            label: container.decode(String.self, forKey: .label),
            hostname: container.decode(String.self, forKey: .hostname),
            port: container.decode(Int.self, forKey: .port),
            username: container.decode(String.self, forKey: .username),
            authenticationKind: container.decode(SSHAuthenticationKind.self, forKey: .authenticationKind),
            reconnectPreference: container.decode(HostReconnectPreference.self, forKey: .reconnectPreference)
        )
    }

    func validate() throws {
        try Self.validate(label: label, hostname: hostname, port: port, username: username)
    }

    private static func validate(label: String, hostname: String, port: Int, username: String) throws {
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard !label.trimmingCharacters(in: whitespace).isEmpty else {
            throw SSHHostValidationError.emptyLabel
        }
        guard !hostname.trimmingCharacters(in: whitespace).isEmpty else {
            throw SSHHostValidationError.emptyHostname
        }
        guard (1...65_535).contains(port) else {
            throw SSHHostValidationError.invalidPort(port)
        }
        guard !username.trimmingCharacters(in: whitespace).isEmpty else {
            throw SSHHostValidationError.emptyUsername
        }
    }
}
