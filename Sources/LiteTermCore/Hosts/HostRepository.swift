import Foundation

public enum HostRepositoryError: Error, Equatable, Sendable {
    case corruptEnvelope
}

public struct HostRecordIssue: Equatable, Sendable {
    public let recordIndex: Int

    public init(recordIndex: Int) {
        self.recordIndex = recordIndex
    }
}

public struct HostRepositorySnapshot: Equatable, Sendable {
    public let hosts: [SSHHost]
    public let issues: [HostRecordIssue]

    public init(hosts: [SSHHost], issues: [HostRecordIssue]) {
        self.hosts = hosts
        self.issues = issues
    }
}

public struct HostRepository: Sendable {
    private static let schemaVersion = 1
    private static let allowedHostKeys: Set<String> = [
        "id",
        "label",
        "hostname",
        "port",
        "username",
        "authenticationKind",
        "reconnectPreference"
    ]
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> HostRepositorySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HostRepositorySnapshot(hosts: [], issues: [])
        }

        let data = try Data(contentsOf: fileURL)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostRepositoryError.corruptEnvelope
        }

        guard
            let envelope = object as? [String: Any],
            Self.isSupportedSchemaVersion(envelope["schemaVersion"]),
            let records = envelope["hosts"] as? [Any]
        else {
            throw HostRepositoryError.corruptEnvelope
        }

        let decoder = JSONDecoder()
        var hosts: [SSHHost] = []
        var issues: [HostRecordIssue] = []
        for (index, record) in records.enumerated() {
            guard
                let recordObject = record as? [String: Any],
                Set(recordObject.keys) == Self.allowedHostKeys,
                let recordData = try? JSONSerialization.data(withJSONObject: record),
                let host = try? decoder.decode(SSHHost.self, from: recordData)
            else {
                issues.append(HostRecordIssue(recordIndex: index))
                continue
            }
            hosts.append(host)
        }

        return HostRepositorySnapshot(hosts: hosts, issues: issues)
    }

    private static func isSupportedSchemaVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        guard String(cString: number.objCType) != "c" else {
            return false
        }
        return number.decimalValue == Decimal(schemaVersion)
    }

    public func save(_ hosts: [SSHHost]) throws {
        for host in hosts {
            try host.validate()
        }

        let envelope = HostRepositoryEnvelope(
            schemaVersion: Self.schemaVersion,
            hosts: hosts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct HostRepositoryEnvelope: Codable {
    let schemaVersion: Int
    let hosts: [SSHHost]
}
