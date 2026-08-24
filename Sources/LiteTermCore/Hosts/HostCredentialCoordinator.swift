import Foundation

public enum HostSecretKind: String, CaseIterable, Hashable, Sendable {
    case password
    case privateKey = "private-key"
    case trustedFingerprint = "trusted-fingerprint"
    case credentialRepair = "credential-repair"
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

public enum HostCredentialCompensationBoundary: Equatable, Sendable {
    case metadata
    case secret(HostSecretKind)
}

public enum HostCredentialCompensationFailure: Equatable, Sendable {
    case metadata
    case secret(HostSecretKind)
    case multiple([HostCredentialCompensationBoundary])
}

public enum HostCredentialTransactionFailure: Equatable, Sendable {
    case metadataSave
    case secretRead(HostSecretKind)
    case secretMutation(HostSecretKind)
    case secretDeletion(HostSecretKind)
    case compensationFailed(
        original: HostSecretKind,
        rollback: HostCredentialCompensationFailure
    )
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
                if try secrets.data(for: host.id, kind: .credentialRepair) != nil {
                    states[host.id] = .repairRequired
                    continue
                }
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
        let credentialSnapshot: HostCredentialSnapshot
        do {
            credentialSnapshot = try snapshotCredentials(for: host.id)
        } catch let failure as HostCredentialSnapshotFailure {
            return outcome(hosts: currentHosts, failure: .secretRead(failure.kind))
        } catch {
            return outcome(hosts: currentHosts, failure: .secretRead(.password))
        }

        let isExistingHost = currentHosts.contains { $0.id == host.id }
        if isExistingHost {
            do {
                try secrets.set(Data([1]), for: host.id, kind: .credentialRepair)
            } catch {
                return outcome(
                    hosts: currentHosts,
                    failure: .secretMutation(.credentialRepair),
                    repairing: host.id
                )
            }
        }

        var updatedHosts = currentHosts
        if let index = updatedHosts.firstIndex(where: { $0.id == host.id }) {
            updatedHosts[index] = host
        } else {
            updatedHosts.append(host)
        }

        do {
            try metadata.save(updatedHosts)
        } catch {
            return outcome(
                hosts: currentHosts,
                failure: .metadataSave,
                repairing: isExistingHost ? host.id : nil
            )
        }

        switch host.authenticationKind {
        case .password:
            if let password {
                do {
                    try secrets.set(password, for: host.id, kind: .password)
                } catch {
                    return compensateUpsert(
                        originalHosts: currentHosts,
                        attemptedHosts: updatedHosts,
                        hostID: host.id,
                        credentialSnapshot: credentialSnapshot,
                        originalFailure: .password
                    )
                }
            } else {
                guard credentialSnapshot.password != nil else {
                    return compensateUpsert(
                        originalHosts: currentHosts,
                        attemptedHosts: updatedHosts,
                        hostID: host.id,
                        credentialSnapshot: credentialSnapshot,
                        originalFailure: .password
                    )
                }
            }
            do {
                try secrets.delete(for: host.id, kind: .privateKey)
            } catch {
                return compensateUpsert(
                    originalHosts: currentHosts,
                    attemptedHosts: updatedHosts,
                    hostID: host.id,
                    credentialSnapshot: credentialSnapshot,
                    originalFailure: .privateKey
                )
            }
        case .generatedKey:
            do {
                try secrets.delete(for: host.id, kind: .password)
            } catch {
                return compensateUpsert(
                    originalHosts: currentHosts,
                    attemptedHosts: updatedHosts,
                    hostID: host.id,
                    credentialSnapshot: credentialSnapshot,
                    originalFailure: .password
                )
            }
        }

        do {
            try secrets.delete(for: host.id, kind: .credentialRepair)
        } catch {
            return compensateUpsert(
                originalHosts: currentHosts,
                attemptedHosts: updatedHosts,
                hostID: host.id,
                credentialSnapshot: credentialSnapshot,
                originalFailure: .credentialRepair
            )
        }

        return outcome(hosts: updatedHosts, failure: nil)
    }

    private func snapshotCredentials(for hostID: UUID) throws -> HostCredentialSnapshot {
        let password: Data?
        do {
            password = try secrets.data(for: hostID, kind: .password)
        } catch {
            throw HostCredentialSnapshotFailure(kind: .password)
        }

        let privateKey: Data?
        do {
            privateKey = try secrets.data(for: hostID, kind: .privateKey)
        } catch {
            throw HostCredentialSnapshotFailure(kind: .privateKey)
        }

        let credentialRepair: Data?
        do {
            credentialRepair = try secrets.data(for: hostID, kind: .credentialRepair)
        } catch {
            throw HostCredentialSnapshotFailure(kind: .credentialRepair)
        }
        return HostCredentialSnapshot(
            password: password,
            privateKey: privateKey,
            credentialRepair: credentialRepair
        )
    }

    private func compensateUpsert(
        originalHosts: [SSHHost],
        attemptedHosts: [SSHHost],
        hostID: UUID,
        credentialSnapshot: HostCredentialSnapshot,
        originalFailure: HostSecretKind
    ) -> HostCredentialTransactionOutcome {
        var rollbackBoundaries: [HostCredentialCompensationBoundary] = []

        func record(_ boundary: HostCredentialCompensationBoundary) {
            if !rollbackBoundaries.contains(boundary) {
                rollbackBoundaries.append(boundary)
            }
        }

        do {
            try restore(
                credentialSnapshot.password,
                for: hostID,
                kind: .password
            )
        } catch {
            record(.secret(.password))
        }

        do {
            try restore(
                credentialSnapshot.privateKey,
                for: hostID,
                kind: .privateKey
            )
        } catch {
            record(.secret(.privateKey))
        }

        do {
            try restore(
                credentialSnapshot.credentialRepair,
                for: hostID,
                kind: .credentialRepair
            )
        } catch {
            record(.secret(.credentialRepair))
        }

        let metadataRestored: Bool
        do {
            try metadata.save(originalHosts)
            metadataRestored = true
        } catch {
            metadataRestored = false
            record(.metadata)
        }

        guard !rollbackBoundaries.isEmpty else {
            return outcome(
                hosts: originalHosts,
                failure: .secretMutation(originalFailure)
            )
        }

        do {
            try secrets.set(Data([1]), for: hostID, kind: .credentialRepair)
        } catch {
            record(.secret(.credentialRepair))
        }

        let rollbackFailure: HostCredentialCompensationFailure
        if rollbackBoundaries.count == 1 {
            switch rollbackBoundaries[0] {
            case .metadata:
                rollbackFailure = .metadata
            case .secret(let kind):
                rollbackFailure = .secret(kind)
            }
        } else {
            rollbackFailure = .multiple(rollbackBoundaries)
        }

        return outcome(
            hosts: metadataRestored ? originalHosts : attemptedHosts,
            failure: .compensationFailed(
                original: originalFailure,
                rollback: rollbackFailure
            ),
            repairing: hostID
        )
    }

    private func restore(
        _ data: Data?,
        for hostID: UUID,
        kind: HostSecretKind
    ) throws {
        if let data {
            try secrets.set(data, for: hostID, kind: kind)
        } else {
            try secrets.delete(for: hostID, kind: kind)
        }
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

private struct HostCredentialSnapshot {
    let password: Data?
    let privateKey: Data?
    let credentialRepair: Data?
}

private struct HostCredentialSnapshotFailure: Error {
    let kind: HostSecretKind
}
