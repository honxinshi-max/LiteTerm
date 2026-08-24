import Combine
import Foundation
import LiteTermCore

enum HostStoreError: Error, LocalizedError {
    case passwordRequired
    case repositoryUnavailable

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "Enter a password for this host."
        case .repositoryUnavailable:
            return "Host metadata cannot be changed until the damaged hosts file is repaired."
        }
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var loadIssues: [HostRecordIssue] = []
    @Published private(set) var errorMessage: String?

    private let repository: HostRepository
    private let keychain: KeychainStore
    private var repositoryAllowsWrites = true

    convenience init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let fileURL = baseURL
            .appendingPathComponent("LiteTerm", isDirectory: true)
            .appendingPathComponent("hosts.json")
        self.init(repository: HostRepository(fileURL: fileURL), keychain: KeychainStore())
    }

    init(repository: HostRepository, keychain: KeychainStore) {
        self.repository = repository
        self.keychain = keychain
        reload()
    }

    func reload() {
        do {
            let snapshot = try repository.load()
            hosts = snapshot.hosts
            loadIssues = snapshot.issues
            repositoryAllowsWrites = true
            errorMessage = snapshot.issues.isEmpty
                ? nil
                : "Ignored \(snapshot.issues.count) malformed host record(s)."
        } catch {
            repositoryAllowsWrites = false
            errorMessage = "Host metadata could not be read: \(error.localizedDescription)"
        }
    }

    func upsert(_ host: SSHHost, password: String?) throws {
        guard repositoryAllowsWrites else {
            throw HostStoreError.repositoryUnavailable
        }

        let existingIndex = hosts.firstIndex { $0.id == host.id }
        if host.authenticationKind == .password, password?.isEmpty != false {
            guard existingIndex != nil,
                  try keychain.data(for: host.id, kind: .password) != nil else {
                throw HostStoreError.passwordRequired
            }
        }

        var updatedHosts = hosts
        if let existingIndex {
            updatedHosts[existingIndex] = host
        } else {
            updatedHosts.append(host)
        }
        try repository.save(updatedHosts)
        hosts = updatedHosts
        loadIssues = []

        do {
            switch host.authenticationKind {
            case .password:
                if let password, !password.isEmpty {
                    try keychain.set(Data(password.utf8), for: host.id, kind: .password)
                }
                try keychain.delete(for: host.id, kind: .privateKey)
            case .generatedKey:
                try keychain.delete(for: host.id, kind: .password)
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        errorMessage = nil
    }

    func delete(_ host: SSHHost) {
        do {
            guard repositoryAllowsWrites else {
                throw HostStoreError.repositoryUnavailable
            }
            let updatedHosts = hosts.filter { $0.id != host.id }
            try repository.save(updatedHosts)
            hosts = updatedHosts
            loadIssues = []
            var firstDeletionError: Error?
            for kind in HostSecretKind.allCases {
                do {
                    try keychain.delete(for: host.id, kind: kind)
                } catch {
                    if firstDeletionError == nil {
                        firstDeletionError = error
                    }
                }
            }
            if let firstDeletionError {
                throw firstDeletionError
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}
