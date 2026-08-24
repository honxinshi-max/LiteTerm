import Foundation
import LiteTermCore
import NIOSSH

struct SSHTerminalDimensions: Equatable, Sendable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    static let fallback = SSHTerminalDimensions(columns: 80, rows: 24)
}

enum SSHClientCredential: Sendable {
    case password(String)
    case generatedKey(NIOSSHPrivateKey)
}

enum SSHStoredHostFingerprint: Equatable, Sendable {
    case absent
    case valid(String)
    case corrupt

    static func classify(storedData: Data?) -> Self {
        guard let storedData else { return .absent }
        guard
            let fingerprint = String(data: storedData, encoding: .utf8),
            KnownHostPolicy.evaluate(
                savedFingerprint: fingerprint,
                presentedFingerprint: fingerprint
            ) == .trusted
        else {
            return .corrupt
        }
        return .valid(fingerprint)
    }
}

enum SSHClientFailure: Equatable, Sendable {
    case transport
    case authenticationRejected
    case hostKeyMismatch
    case credentialUnavailable
    case trustCancelled
    case protocolFailure

    var stateCategory: SSHFailureCategory {
        switch self {
        case .transport:
            return .transport
        case .authenticationRejected:
            return .authenticationRejected
        case .hostKeyMismatch:
            return .hostKeyMismatch
        case .credentialUnavailable:
            return .credentialUnavailable
        case .trustCancelled:
            return .trustCancelled
        case .protocolFailure:
            return .protocolFailure
        }
    }
}

struct SSHClientCallbacks: Sendable {
    let hostTrustRequired: @Sendable (String, SSHHostTrustKind) -> Void
    let hostKeyValidated: @Sendable () -> Void
    let terminalReady: @Sendable () -> Void
    let receiveBytes: @Sendable (
        [UInt8],
        @escaping @Sendable () -> Void
    ) -> Void
    let connectionClosed: @Sendable (SSHClientFailure) -> Void
}

struct LiteTermSSHClientConfiguration: Sendable {
    let host: SSHHost
    let credential: SSHClientCredential
    let storedFingerprint: SSHStoredHostFingerprint
    let terminalDimensions: SSHTerminalDimensions
    let callbacks: SSHClientCallbacks
}

protocol SSHClientTransport: AnyObject {
    func connect()
    func send(_ bytes: [UInt8])
    func resize(columns: Int, rows: Int)
    func confirmHostTrust()
    func rejectHostTrust(as failure: SSHClientFailure)
    func close(completion: @escaping @Sendable () -> Void)
}
