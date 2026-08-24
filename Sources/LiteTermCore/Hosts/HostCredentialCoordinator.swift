import Foundation

public enum HostSecretKind: String, CaseIterable, Hashable, Sendable {
    case password
    case privateKey = "private-key"
    case trustedFingerprint = "trusted-fingerprint"
}

public protocol HostMetadataStoring {
    func save(_ hosts: [SSHHost]) throws
}

extension HostRepository: HostMetadataStoring {}

public protocol HostSecretStoring {
    func set(_ data: Data, for hostID: UUID, kind: HostSecretKind) throws
    func data(for hostID: UUID, kind: HostSecretKind) throws -> Data?
    func delete(for hostID: UUID, kind: HostSecretKind) throws
}

public enum HostCredentialState: Equatable, Sendable {
    case ready
    case setupRequired
    case repairRequired
}

public enum HostCredentialTransactionFailure: Equatable, Sendable {
    case metadataSave
    case secretMutation(HostSecretKind)
    case secretDeletion(HostSecretKind)
}

public struct HostCredentialTransactionOutcome: Equatable, Sendable {
    public let hosts: [SSHHost]
    public let credentialStates: [UUID: HostCredentialState]
    public let failure: HostCredentialTransactionFailure?

    public init(
        hosts: [SSHHost],
        credentialStates: [UUID: HostCredentialState],
        failure: HostCredentialTransactionFailure?
    ) {
        self.hosts = hosts
        self.credentialStates = credentialStates
        self.failure = failure
    }
}

public struct HostCredentialCoordinator {
    private let metadata: any HostMetadataStoring
    private let secrets: any HostSecretStoring

    public init(metadata: any HostMetadataStoring, secrets: any HostSecretStoring) {
        self.metadata = metadata
        self.secrets = secrets
    }

    public func inspect(_ hosts: [SSHHost]) -> [UUID: HostCredentialState] {
        var states: [UUID: HostCredentialState] = [:]
        for host in hosts {
            do {
                let hasPassword = try secrets.data(for: host.id, kind: .password) != nil
                let hasPrivateKey = try secrets.data(for: host.id, kind: .privateKey) != nil
                switch host.authenticationKind {
                case .password:
                    if hasPassword && !hasPrivateKey {
                        states[host.id] = .ready
                    } else if !hasPassword && !hasPrivateKey {
                        states[host.id] = .setupRequired
                    } else {
                        states[host.id] = .repairRequired
                    }
                case .generatedKey:
                    if hasPrivateKey && !hasPassword {
                        states[host.id] = .ready
                    } else if !hasPrivateKey && !hasPassword {
                        states[host.id] = .setupRequired
                    } else {
                        states[host.id] = .repairRequired
                    }
                }
            } catch {
                states[host.id] = .repairRequired
            }
        }
        return states
    }

    public func upsert(
        _ host: SSHHost,
        password: Data?,
        in currentHosts: [SSHHost]
    ) -> HostCredentialTransactionOutcome {
        var updatedHosts = currentHosts
        if let index = updatedHosts.firstIndex(where: { $0.id == host.id }) {
            updatedHosts[index] = host
        } else {
            updatedHosts.append(host)
        }

        do {
            try metadata.save(updatedHosts)
        } catch {
            return outcome(hosts: currentHosts, failure: .metadataSave)
        }

        switch host.authenticationKind {
        case .password:
            if let password {
                do {
                    try secrets.set(password, for: host.id, kind: .password)
                } catch {
                    return outcome(
                        hosts: updatedHosts,
                        failure: .secretMutation(.password),
                        repairing: host.id
                    )
                }
            } else {
                do {
                    guard try secrets.data(for: host.id, kind: .password) != nil else {
                        return outcome(
                            hosts: updatedHosts,
                            failure: .secretMutation(.password),
                            repairing: host.id
                        )
                    }
                } catch {
                    return outcome(
                        hosts: updatedHosts,
                        failure: .secretMutation(.password),
                        repairing: host.id
                    )
                }
            }
            do {
                try secrets.delete(for: host.id, kind: .privateKey)
            } catch {
                return outcome(
                    hosts: updatedHosts,
                    failure: .secretMutation(.privateKey),
                    repairing: host.id
                )
            }
        case .generatedKey:
            do {
                try secrets.delete(for: host.id, kind: .password)
            } catch {
                return outcome(
                    hosts: updatedHosts,
                    failure: .secretMutation(.password),
                    repairing: host.id
                )
            }
        }

        return outcome(hosts: updatedHosts, failure: nil)
    }

    public func delete(
        _ host: SSHHost,
        from currentHosts: [SSHHost]
    ) -> HostCredentialTransactionOutcome {
        for kind in HostSecretKind.allCases {
            do {
                try secrets.delete(for: host.id, kind: kind)
            } catch {
                return outcome(
                    hosts: currentHosts,
                    failure: .secretDeletion(kind),
                    repairing: host.id
                )
            }
        }

        let updatedHosts = currentHosts.filter { $0.id != host.id }
        do {
            try metadata.save(updatedHosts)
        } catch {
            return outcome(
                hosts: currentHosts,
                failure: .metadataSave,
                repairing: host.id
            )
        }
        return outcome(hosts: updatedHosts, failure: nil)
    }

    private func outcome(
        hosts: [SSHHost],
        failure: HostCredentialTransactionFailure?,
        repairing hostID: UUID? = nil
    ) -> HostCredentialTransactionOutcome {
        var states = inspect(hosts)
        if let hostID, hosts.contains(where: { $0.id == hostID }) {
            states[hostID] = .repairRequired
        }
        return HostCredentialTransactionOutcome(
            hosts: hosts,
            credentialStates: states,
            failure: failure
        )
    }
}
