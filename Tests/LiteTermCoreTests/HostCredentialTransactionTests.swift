import Foundation
import XCTest
@testable import LiteTermCore

final class HostCredentialTransactionTests: XCTestCase {
    func testPasswordWriteFailureKeepsNewHostVisibleAndRepairRequired() throws {
        let metadata = TestHostMetadataStore()
        let secrets = TestHostSecretStore()
        secrets.failingSetKinds = [.password]
        let host = try makeHost(authenticationKind: .password)
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(host, password: Data("credential".utf8), in: [])

        XCTAssertEqual(outcome.hosts, [host])
        XCTAssertEqual(metadata.hosts, [host])
        XCTAssertEqual(outcome.credentialStates[host.id], .repairRequired)
        XCTAssertEqual(outcome.failure, .secretMutation(.password))
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
        XCTAssertEqual(coordinator.inspect([host])[host.id], .setupRequired)

        secrets.failingSetKinds = []
        let retried = coordinator.upsert(
            host,
            password: Data("credential".utf8),
            in: outcome.hosts
        )
        XCTAssertEqual(retried.hosts, [host])
        XCTAssertEqual(retried.credentialStates[host.id], .ready)
        XCTAssertEqual(retried.failure, nil)
    }

    func testPrivateKeyCleanupFailureKeepsEditedHostVisible() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let oldHost = try makeHost(id: id, authenticationKind: .generatedKey)
        let updatedHost = try makeHost(id: id, authenticationKind: .password)
        let metadata = TestHostMetadataStore(hosts: [oldHost])
        let secrets = TestHostSecretStore()
        secrets.seed(Data("generated-key".utf8), for: id, kind: .privateKey)
        secrets.failingDeleteKinds = [.privateKey]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            updatedHost,
            password: Data("credential".utf8),
            in: [oldHost]
        )

        XCTAssertEqual(outcome.hosts, [updatedHost])
        XCTAssertEqual(metadata.hosts, [updatedHost])
        XCTAssertEqual(outcome.credentialStates[id], .repairRequired)
        XCTAssertEqual(outcome.failure, .secretMutation(.privateKey))
        XCTAssertEqual(secrets.hasValue(for: id, kind: .password), true)
        XCTAssertEqual(secrets.hasValue(for: id, kind: .privateKey), true)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testGeneratedKeyPasswordCleanupFailureKeepsHostVisible() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let oldHost = try makeHost(id: id, authenticationKind: .password)
        let updatedHost = try makeHost(id: id, authenticationKind: .generatedKey)
        let metadata = TestHostMetadataStore(hosts: [oldHost])
        let secrets = TestHostSecretStore()
        secrets.seed(Data("credential".utf8), for: id, kind: .password)
        secrets.failingDeleteKinds = [.password]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(updatedHost, password: nil, in: [oldHost])

        XCTAssertEqual(outcome.hosts, [updatedHost])
        XCTAssertEqual(metadata.hosts, [updatedHost])
        XCTAssertEqual(outcome.credentialStates[id], .repairRequired)
        XCTAssertEqual(outcome.failure, .secretMutation(.password))
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testEverySecretDeletionFailureKeepsHostVisibleAndRetryCleansRemainder() throws {
        for failingKind in HostSecretKind.allCases {
            let host = try makeHost(authenticationKind: .password)
            let metadata = TestHostMetadataStore(hosts: [host])
            let secrets = TestHostSecretStore()
            for kind in HostSecretKind.allCases {
                secrets.seed(Data("fixture-\(kind.rawValue)".utf8), for: host.id, kind: kind)
            }
            secrets.failingDeleteKinds = [failingKind]
            let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

            let failed = coordinator.delete(host, from: [host])

            XCTAssertEqual(failed.hosts, [host])
            XCTAssertEqual(metadata.hosts, [host])
            XCTAssertEqual(failed.credentialStates[host.id], .repairRequired)
            XCTAssertEqual(failed.failure, .secretDeletion(failingKind))
            assertNoSecretOnlyHosts(failed.hosts, secrets: secrets)

            secrets.failingDeleteKinds = []
            let retried = coordinator.delete(host, from: failed.hosts)

            XCTAssertEqual(retried.hosts, [])
            XCTAssertEqual(metadata.hosts, [])
            XCTAssertEqual(retried.failure, nil)
            XCTAssertEqual(secrets.hostIDsWithValues, [])
        }
    }

    func testUpsertMetadataFailureDoesNotCreateSecretOnlyUUID() throws {
        let host = try makeHost(authenticationKind: .password)
        let metadata = TestHostMetadataStore()
        metadata.saveShouldFail = true
        let secrets = TestHostSecretStore()
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(host, password: Data("credential".utf8), in: [])

        XCTAssertEqual(outcome.hosts, [])
        XCTAssertEqual(metadata.hosts, [])
        XCTAssertEqual(outcome.failure, .metadataSave)
        XCTAssertEqual(secrets.mutationCount, 0)
        XCTAssertEqual(secrets.hostIDsWithValues, [])
    }

    func testDeleteMetadataFailureKeepsHostVisibleAndNonHealthyAfterRestart() throws {
        let host = try makeHost(authenticationKind: .password)
        let metadata = TestHostMetadataStore(hosts: [host])
        metadata.saveShouldFail = true
        let secrets = TestHostSecretStore()
        secrets.seed(Data("credential".utf8), for: host.id, kind: .password)
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.delete(host, from: [host])

        XCTAssertEqual(outcome.hosts, [host])
        XCTAssertEqual(metadata.hosts, [host])
        XCTAssertEqual(outcome.credentialStates[host.id], .repairRequired)
        XCTAssertEqual(outcome.failure, .metadataSave)
        XCTAssertEqual(secrets.hostIDsWithValues, [])
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[host.id], .setupRequired)

        metadata.saveShouldFail = false
        let retried = coordinator.delete(host, from: outcome.hosts)
        XCTAssertEqual(retried.hosts, [])
        XCTAssertEqual(metadata.hosts, [])
        XCTAssertEqual(retried.failure, nil)
    }

    private func makeHost(
        id: UUID = UUID(),
        authenticationKind: SSHAuthenticationKind
    ) throws -> SSHHost {
        try SSHHost(
            id: id,
            label: "Primary",
            hostname: "server.example",
            port: 22,
            username: "alice",
            authenticationKind: authenticationKind,
            reconnectPreference: .enabled
        )
    }

    private func assertNoSecretOnlyHosts(
        _ hosts: [SSHHost],
        secrets: TestHostSecretStore
    ) {
        let visibleIDs = Set(hosts.map(\.id))
        XCTAssertEqual(secrets.hostIDsWithValues.isSubset(of: visibleIDs), true)
    }
}

private enum TestHostStoreFailure: Error {
    case injected
}

private final class TestHostMetadataStore: HostMetadataStoring {
    var hosts: [SSHHost]
    var saveShouldFail = false

    init(hosts: [SSHHost] = []) {
        self.hosts = hosts
    }

    func save(_ hosts: [SSHHost]) throws {
        guard !saveShouldFail else {
            throw TestHostStoreFailure.injected
        }
        self.hosts = hosts
    }
}

private final class TestHostSecretStore: HostSecretStoring {
    struct Key: Hashable {
        let hostID: UUID
        let kind: HostSecretKind
    }

    var failingSetKinds: Set<HostSecretKind> = []
    var failingDeleteKinds: Set<HostSecretKind> = []
    private(set) var mutationCount = 0
    private var values: [Key: Data] = [:]

    var hostIDsWithValues: Set<UUID> {
        Set(values.keys.map(\.hostID))
    }

    func seed(_ data: Data, for hostID: UUID, kind: HostSecretKind) {
        values[Key(hostID: hostID, kind: kind)] = data
    }

    func hasValue(for hostID: UUID, kind: HostSecretKind) -> Bool {
        values[Key(hostID: hostID, kind: kind)] != nil
    }

    func set(_ data: Data, for hostID: UUID, kind: HostSecretKind) throws {
        mutationCount += 1
        guard !failingSetKinds.contains(kind) else {
            throw TestHostStoreFailure.injected
        }
        values[Key(hostID: hostID, kind: kind)] = data
    }

    func data(for hostID: UUID, kind: HostSecretKind) throws -> Data? {
        values[Key(hostID: hostID, kind: kind)]
    }

    func delete(for hostID: UUID, kind: HostSecretKind) throws {
        mutationCount += 1
        guard !failingDeleteKinds.contains(kind) else {
            throw TestHostStoreFailure.injected
        }
        values.removeValue(forKey: Key(hostID: hostID, kind: kind))
    }
}
