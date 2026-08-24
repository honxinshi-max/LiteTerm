import Foundation
import XCTest
@testable import LiteTermCore

final class HostCredentialTransactionTests: XCTestCase {
    func testExistingPasswordReplacementFailureRestoresOriginalMetadataAndPassword() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let originalHost = try SSHHost(
            id: id,
            label: "Original",
            hostname: "old.example",
            port: 22,
            username: "old-user",
            authenticationKind: .password,
            reconnectPreference: .enabled
        )
        let editedHost = try SSHHost(
            id: id,
            label: "Edited",
            hostname: "new.example",
            port: 2222,
            username: "new-user",
            authenticationKind: .password,
            reconnectPreference: .disabled
        )
        let beforeHost = try makeHost(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            authenticationKind: .generatedKey
        )
        let afterHost = try makeHost(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            authenticationKind: .generatedKey
        )
        let originalHosts = [beforeHost, originalHost, afterHost]
        let oldPassword = Data("old-password".utf8)
        let metadata = TestHostMetadataStore(hosts: originalHosts)
        let secrets = TestHostSecretStore()
        secrets.seed(oldPassword, for: id, kind: .password)
        secrets.failNextSetKinds = [.password]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            editedHost,
            password: Data("replacement-password".utf8),
            in: originalHosts
        )

        XCTAssertEqual(outcome.hosts, originalHosts)
        XCTAssertEqual(metadata.hosts, originalHosts)
        XCTAssertEqual(secrets.value(for: id, kind: .password), oldPassword)
        XCTAssertEqual(secrets.hasValue(for: id, kind: .credentialRepair), false)
        XCTAssertEqual(outcome.credentialStates[id], .ready)
        XCTAssertEqual(outcome.failure, .secretMutation(.password))

        let restartedStates = coordinator.inspect(metadata.hosts)
        XCTAssertEqual(metadata.hosts.contains(editedHost), false)
        XCTAssertEqual(restartedStates[id], .ready)
    }

    func testPasswordWriteFailureRestoresOriginalEmptyMetadataBeforeRetry() throws {
        let metadata = TestHostMetadataStore()
        let secrets = TestHostSecretStore()
        secrets.failingSetKinds = [.password]
        let host = try makeHost(authenticationKind: .password)
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(host, password: Data("credential".utf8), in: [])

        XCTAssertEqual(outcome.hosts, [])
        XCTAssertEqual(metadata.hosts, [])
        XCTAssertEqual(outcome.credentialStates[host.id], nil)
        XCTAssertEqual(outcome.failure, .secretMutation(.password))
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)

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

    func testAuthenticationKindSwitchPartialFailureRestoresOriginalHostAndCredentials() throws {
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

        XCTAssertEqual(outcome.hosts, [oldHost])
        XCTAssertEqual(metadata.hosts, [oldHost])
        XCTAssertEqual(outcome.credentialStates[id], .ready)
        XCTAssertEqual(outcome.failure, .secretMutation(.privateKey))
        XCTAssertEqual(secrets.hasValue(for: id, kind: .password), false)
        XCTAssertEqual(secrets.hasValue(for: id, kind: .privateKey), true)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[id], .ready)
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

        XCTAssertEqual(outcome.hosts, [oldHost])
        XCTAssertEqual(metadata.hosts, [oldHost])
        XCTAssertEqual(outcome.credentialStates[id], .ready)
        XCTAssertEqual(outcome.failure, .secretMutation(.password))
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testSecretCompensationFailureRestoresMetadataButForcesRepair() throws {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let oldHost = try makeHost(id: id, authenticationKind: .generatedKey)
        let updatedHost = try makeHost(id: id, authenticationKind: .password)
        let oldPrivateKey = Data("old-generated-key".utf8)
        let metadata = TestHostMetadataStore(hosts: [oldHost])
        let secrets = TestHostSecretStore()
        secrets.seed(oldPrivateKey, for: id, kind: .privateKey)
        secrets.failNextDeleteKinds = [.privateKey]
        secrets.failingDeleteKinds = [.password]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            updatedHost,
            password: Data("new-password".utf8),
            in: [oldHost]
        )

        XCTAssertEqual(outcome.hosts, [oldHost])
        XCTAssertEqual(metadata.hosts, [oldHost])
        XCTAssertEqual(outcome.credentialStates[id], .repairRequired)
        XCTAssertEqual(
            outcome.failure,
            .compensationFailed(original: .privateKey, rollback: .secret(.password))
        )
        XCTAssertEqual(secrets.hasValue(for: id, kind: .password), true)
        XCTAssertEqual(secrets.value(for: id, kind: .privateKey), oldPrivateKey)
        XCTAssertEqual(secrets.hasValue(for: id, kind: .credentialRepair), true)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[id], .repairRequired)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testMetadataCompensationFailureKeepsPersistedEditedHostVisibleAndRepairRequired() throws {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let oldHost = try SSHHost(
            id: id,
            label: "Original",
            hostname: "old.example",
            port: 22,
            username: "old-user",
            authenticationKind: .password,
            reconnectPreference: .enabled
        )
        let updatedHost = try SSHHost(
            id: id,
            label: "Edited",
            hostname: "new.example",
            port: 2222,
            username: "new-user",
            authenticationKind: .password,
            reconnectPreference: .disabled
        )
        let oldPassword = Data("old-password".utf8)
        let metadata = TestHostMetadataStore(hosts: [oldHost])
        metadata.failingSaveCalls = [2]
        let secrets = TestHostSecretStore()
        secrets.seed(oldPassword, for: id, kind: .password)
        secrets.failNextSetKinds = [.password]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            updatedHost,
            password: Data("new-password".utf8),
            in: [oldHost]
        )

        XCTAssertEqual(outcome.hosts, [updatedHost])
        XCTAssertEqual(metadata.hosts, [updatedHost])
        XCTAssertEqual(outcome.credentialStates[id], .repairRequired)
        XCTAssertEqual(
            outcome.failure,
            .compensationFailed(original: .password, rollback: .metadata)
        )
        XCTAssertEqual(secrets.value(for: id, kind: .password), oldPassword)
        XCTAssertEqual(secrets.hasValue(for: id, kind: .credentialRepair), true)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[id], .repairRequired)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testMultipleCompensationFailuresReportEveryNonSecretBoundary() throws {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let oldHost = try makeHost(id: id, authenticationKind: .generatedKey)
        let updatedHost = try makeHost(id: id, authenticationKind: .password)
        let metadata = TestHostMetadataStore(hosts: [oldHost])
        metadata.failingSaveCalls = [2]
        let secrets = TestHostSecretStore()
        secrets.seed(Data("old-key".utf8), for: id, kind: .privateKey)
        secrets.failNextDeleteKinds = [.privateKey]
        secrets.failingDeleteKinds = [.password]
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            updatedHost,
            password: Data("new-password".utf8),
            in: [oldHost]
        )

        XCTAssertEqual(outcome.hosts, [updatedHost])
        XCTAssertEqual(metadata.hosts, [updatedHost])
        XCTAssertEqual(outcome.credentialStates[id], .repairRequired)
        XCTAssertEqual(
            outcome.failure,
            .compensationFailed(
                original: .privateKey,
                rollback: .multiple([.secret(.password), .metadata])
            )
        )
        XCTAssertEqual(secrets.hasValue(for: id, kind: .credentialRepair), true)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[id], .repairRequired)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
    }

    func testSuccessfulUpsertClearsDurableRepairMarker() throws {
        let host = try makeHost(authenticationKind: .password)
        let metadata = TestHostMetadataStore(hosts: [host])
        let secrets = TestHostSecretStore()
        secrets.seed(Data("old-password".utf8), for: host.id, kind: .password)
        secrets.seed(Data([1]), for: host.id, kind: .credentialRepair)
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            host,
            password: Data("new-password".utf8),
            in: [host]
        )

        XCTAssertEqual(outcome.hosts, [host])
        XCTAssertEqual(outcome.failure, nil)
        XCTAssertEqual(outcome.credentialStates[host.id], .ready)
        XCTAssertEqual(secrets.hasValue(for: host.id, kind: .credentialRepair), false)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[host.id], .ready)
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

    func testExistingHostMetadataSaveFailureLeavesDurableRepairMarker() throws {
        let host = try makeHost(authenticationKind: .password)
        let oldPassword = Data("old-password".utf8)
        let metadata = TestHostMetadataStore(hosts: [host])
        metadata.saveShouldFail = true
        let secrets = TestHostSecretStore()
        secrets.seed(oldPassword, for: host.id, kind: .password)
        let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)

        let outcome = coordinator.upsert(
            host,
            password: Data("new-password".utf8),
            in: [host]
        )

        XCTAssertEqual(outcome.hosts, [host])
        XCTAssertEqual(metadata.hosts, [host])
        XCTAssertEqual(outcome.failure, .metadataSave)
        XCTAssertEqual(outcome.credentialStates[host.id], .repairRequired)
        XCTAssertEqual(secrets.value(for: host.id, kind: .password), oldPassword)
        XCTAssertEqual(secrets.hasValue(for: host.id, kind: .credentialRepair), true)
        XCTAssertEqual(coordinator.inspect(metadata.hosts)[host.id], .repairRequired)
        assertNoSecretOnlyHosts(outcome.hosts, secrets: secrets)
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
    var failingSaveCalls: Set<Int> = []
    private(set) var saveCallCount = 0

    init(hosts: [SSHHost] = []) {
        self.hosts = hosts
    }

    func save(_ hosts: [SSHHost]) throws {
        saveCallCount += 1
        guard !saveShouldFail, !failingSaveCalls.contains(saveCallCount) else {
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
    var failNextSetKinds: Set<HostSecretKind> = []
    var failingDeleteKinds: Set<HostSecretKind> = []
    var failNextDeleteKinds: Set<HostSecretKind> = []
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

    func value(for hostID: UUID, kind: HostSecretKind) -> Data? {
        values[Key(hostID: hostID, kind: kind)]
    }

    func set(_ data: Data, for hostID: UUID, kind: HostSecretKind) throws {
        mutationCount += 1
        if failNextSetKinds.remove(kind) != nil {
            throw TestHostStoreFailure.injected
        }
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
        if failNextDeleteKinds.remove(kind) != nil {
            throw TestHostStoreFailure.injected
        }
        guard !failingDeleteKinds.contains(kind) else {
            throw TestHostStoreFailure.injected
        }
        values.removeValue(forKey: Key(hostID: hostID, kind: kind))
    }
}
