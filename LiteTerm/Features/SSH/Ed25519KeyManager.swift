import Crypto
import Foundation
import LiteTermCore
import NIOSSH

enum Ed25519KeyManagerError: Error, LocalizedError {
    case keyNotGenerated
    case invalidStoredKey

    var errorDescription: String? {
        switch self {
        case .keyNotGenerated:
            return "Generate the LiteTerm Ed25519 key before connecting."
        case .invalidStoredKey:
            return "The saved LiteTerm Ed25519 key is invalid and must be repaired."
        }
    }
}

final class Ed25519KeyManager {
    private let secrets: any HostSecretStoring

    init(secrets: any HostSecretStoring) {
        self.secrets = secrets
    }

    func generateIfNeeded(for hostID: UUID) throws -> String {
        if let existing = try secrets.data(for: hostID, kind: .privateKey) {
            return try openSSHPublicKey(from: existing)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        try secrets.set(privateKey.rawRepresentation, for: hostID, kind: .privateKey)
        return openSSHPublicKey(for: NIOSSHPrivateKey(ed25519Key: privateKey))
    }

    func privateKey(for hostID: UUID) throws -> NIOSSHPrivateKey {
        guard let data = try secrets.data(for: hostID, kind: .privateKey) else {
            throw Ed25519KeyManagerError.keyNotGenerated
        }
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            return NIOSSHPrivateKey(ed25519Key: key)
        } catch {
            throw Ed25519KeyManagerError.invalidStoredKey
        }
    }

    func publicKey(for hostID: UUID) throws -> String {
        guard let data = try secrets.data(for: hostID, kind: .privateKey) else {
            throw Ed25519KeyManagerError.keyNotGenerated
        }
        return try openSSHPublicKey(from: data)
    }

    private func openSSHPublicKey(from rawPrivateKey: Data) throws -> String {
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
            return openSSHPublicKey(for: NIOSSHPrivateKey(ed25519Key: key))
        } catch {
            throw Ed25519KeyManagerError.invalidStoredKey
        }
    }

    private func openSSHPublicKey(for privateKey: NIOSSHPrivateKey) -> String {
        String(openSSHPublicKey: privateKey.publicKey) + " LiteTerm"
    }
}
