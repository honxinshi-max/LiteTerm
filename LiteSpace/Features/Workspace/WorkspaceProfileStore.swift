import CryptoKit
import Foundation
import LiteSpaceCore

public actor WorkspaceProfileStore {
    private let defaults: UserDefaults
    private let namespace: String

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "LiteSpace.workspaceProfile.v1"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    public func load(rootIdentity: Data) throws -> WorkspaceProfile? {
        guard !rootIdentity.isEmpty else {
            throw WorkspaceFileServiceError.invalidRootIdentity
        }
        guard let encoded = defaults.data(forKey: key(rootIdentity: rootIdentity)) else {
            return nil
        }
        return try JSONDecoder().decode(WorkspaceProfile.self, from: encoded)
    }

    public func save(_ profile: WorkspaceProfile, rootIdentity: Data) throws {
        guard !rootIdentity.isEmpty else {
            throw WorkspaceFileServiceError.invalidRootIdentity
        }
        let encoded = try JSONEncoder().encode(profile)
        defaults.set(encoded, forKey: key(rootIdentity: rootIdentity))
    }

    private func key(rootIdentity: Data) -> String {
        var input = Data(namespace.utf8)
        input.append(0)
        input.append(rootIdentity)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return "LiteSpace.workspaceProfile.\(digest)"
    }
}
