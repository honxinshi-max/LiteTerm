import Foundation
import XCTest
@testable import LiteTermCore

final class HostRepositoryTests: XCTestCase {
    func testHostMetadataEncodingContainsNoSecretFields() throws {
        let host = try makeHost(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

        let data = try JSONEncoder().encode(host)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(json.contains(#""password":"#), false)
        XCTAssertEqual(json.contains(#""privateKey":"#), false)
        XCTAssertEqual(json.contains(#""fingerprint":"#), false)
    }

    func testRepositoryRoundTripPreservesStableHostOrder() throws {
        let fileURL = temporaryRepositoryURL()
        let first = try makeHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "Zulu"
        )
        let second = try makeHost(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "Alpha",
            authenticationKind: .generatedKey,
            reconnectPreference: .disabled
        )
        let repository = HostRepository(fileURL: fileURL)

        try repository.save([first, second])
        let snapshot = try repository.load()

        XCTAssertEqual(snapshot.hosts, [first, second])
        XCTAssertEqual(snapshot.issues, [])
    }

    func testMalformedRecordIsReportedWithoutDiscardingValidRecords() throws {
        let fileURL = temporaryRepositoryURL()
        let repository = HostRepository(fileURL: fileURL)
        let json = """
        {
          "schemaVersion": 1,
          "hosts": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "label": "Primary",
              "hostname": "server.example",
              "port": 22,
              "username": "alice",
              "authenticationKind": "password",
              "reconnectPreference": "enabled"
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "label": "Broken",
              "hostname": "   ",
              "port": 22,
              "username": "bob",
              "authenticationKind": "password",
              "reconnectPreference": "enabled"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "label": "Secondary",
              "hostname": "backup.example",
              "port": 2222,
              "username": "carol",
              "authenticationKind": "generatedKey",
              "reconnectPreference": "disabled"
            }
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL, options: .atomic)

        let snapshot = try repository.load()

        XCTAssertEqual(snapshot.hosts.map(\.label), ["Primary", "Secondary"])
        XCTAssertEqual(snapshot.issues.map(\.recordIndex), [1])
    }

    func testWhollyCorruptEnvelopeSurfacesErrorWithoutChangingFile() throws {
        let fileURL = temporaryRepositoryURL()
        let corruptData = Data(#"{"schemaVersion":1,"hosts":["#.utf8)
        try corruptData.write(to: fileURL, options: .atomic)
        let repository = HostRepository(fileURL: fileURL)

        do {
            _ = try repository.load()
            XCTFail("Expected a corrupt-envelope error")
        } catch let error as HostRepositoryError {
            XCTAssertEqual(error, .corruptEnvelope)
        }

        let unchangedData = try Data(contentsOf: fileURL)
        XCTAssertEqual(unchangedData, corruptData)
    }

    func testHostRejectsBlankLabel() throws {
        assertValidationError(.emptyLabel) {
            _ = try makeHost(label: " \n ")
        }
    }

    func testHostRejectsBlankHostname() throws {
        assertValidationError(.emptyHostname) {
            _ = try makeHost(hostname: "\t")
        }
    }

    func testHostRejectsPortOutsideValidRange() throws {
        assertValidationError(.invalidPort(0)) {
            _ = try makeHost(port: 0)
        }
        assertValidationError(.invalidPort(65_536)) {
            _ = try makeHost(port: 65_536)
        }
    }

    func testHostRejectsBlankUsername() throws {
        assertValidationError(.emptyUsername) {
            _ = try makeHost(username: "  ")
        }
    }

    private func makeHost(
        id: UUID = UUID(),
        label: String = "Primary",
        hostname: String = "server.example",
        port: Int = 22,
        username: String = "alice",
        authenticationKind: SSHAuthenticationKind = .password,
        reconnectPreference: HostReconnectPreference = .enabled
    ) throws -> SSHHost {
        try SSHHost(
            id: id,
            label: label,
            hostname: hostname,
            port: port,
            username: username,
            authenticationKind: authenticationKind,
            reconnectPreference: reconnectPreference
        )
    }

    private func assertValidationError(
        _ expected: SSHHostValidationError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected validation error \(expected)")
        } catch let error as SSHHostValidationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func temporaryRepositoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-HostRepositoryTests-\(UUID().uuidString)")
            .appendingPathComponent("hosts.json")
    }
}
