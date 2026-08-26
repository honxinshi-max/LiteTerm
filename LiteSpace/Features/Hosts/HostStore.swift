import Combine
import Foundation
import LiteSpaceCore

enum HostStoreError: Error, LocalizedError {
    case passwordRequired
    case repositoryUnavailable
    case credentialTransactionFailed

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "Enter a password for this host."
        case .repositoryUnavailable:
            return "Host metadata cannot be changed until the damaged hosts file is repaired."
        case .credentialTransactionFailed:
            return "The credential change was not committed. Retry the operation; any host requiring repair remains visible."
        }
    }
}

struct GeneratedPublicKeyPresentation: Identifiable {
    let hostID: UUID
    let hostLabel: String
    let publicKey: String

    var id: UUID { hostID }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var loadIssues: [HostRecordIssue] = []
    @Published private(set) var credentialStates: [UUID: HostCredentialState] = [:]
    @Published private(set) var errorMessage: String?
    @Published var generatedPublicKey: GeneratedPublicKeyPresentation?

    private let repository: HostRepository
    private let secrets: any HostSecretStoring
    private let credentialCoordinator: HostCredentialCoordinator
    private let keyManager: Ed25519KeyManager
    private var repositoryAllowsWrites = true

    convenience init() {
        self.init(secrets: KeychainStore())
    }

    convenience init(secrets: any HostSecretStoring) {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let fileURL = baseURL
            .appendingPathComponent("LiteSpace", isDirectory: true)
            .appendingPathComponent("hosts.json")
        self.init(repository: HostRepository(fileURL: fileURL), secrets: secrets)
    }

    init(repository: HostRepository, secrets: any HostSecretStoring) {
        self.repository = repository
        self.secrets = secrets
        credentialCoordinator = HostCredentialCoordinator(metadata: repository, secrets: secrets)
        keyManager = Ed25519KeyManager(secrets: secrets)
        reload()
    }

    func reload() {
        do {
            let snapshot = try repository.load()
            hosts = snapshot.hosts
            loadIssues = snapshot.issues
            credentialStates = credentialCoordinator.inspect(snapshot.hosts)
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
                  try secrets.data(for: host.id, kind: .password) != nil else {
                throw HostStoreError.passwordRequired
            }
        }

        let outcome = credentialCoordinator.upsert(
            host,
            password: password.map { Data($0.utf8) },
            in: hosts
        )
        hosts = outcome.hosts
        credentialStates = outcome.credentialStates
        if outcome.failure == nil {
            loadIssues = []
            errorMessage = nil
            return
        }
        errorMessage = HostStoreError.credentialTransactionFailed.localizedDescription
        throw HostStoreError.credentialTransactionFailed
    }

    func delete(_ host: SSHHost) {
        do {
            guard repositoryAllowsWrites else {
                throw HostStoreError.repositoryUnavailable
            }
            let outcome = credentialCoordinator.delete(host, from: hosts)
            hosts = outcome.hosts
            credentialStates = outcome.credentialStates
            if outcome.failure == nil {
                loadIssues = []
                errorMessage = nil
            } else {
                throw HostStoreError.credentialTransactionFailed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateKey(for host: SSHHost) {
        do {
            guard host.authenticationKind == .generatedKey else { return }
            let publicKey = try keyManager.generateIfNeeded(for: host.id)
            credentialStates = credentialCoordinator.inspect(hosts)
            generatedPublicKey = GeneratedPublicKeyPresentation(
                hostID: host.id,
                hostLabel: host.label,
                publicKey: publicKey
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showGeneratedPublicKey(for host: SSHHost) {
        do {
            generatedPublicKey = GeneratedPublicKeyPresentation(
                hostID: host.id,
                hostLabel: host.label,
                publicKey: try keyManager.publicKey(for: host.id)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissGeneratedPublicKey() {
        generatedPublicKey = nil
    }

    func dismissError() {
        errorMessage = nil
    }
}
