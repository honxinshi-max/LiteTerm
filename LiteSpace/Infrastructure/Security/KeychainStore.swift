import Foundation
import LiteSpaceCore
import Security

enum KeychainStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed (status \(status))."
        case .unexpectedData:
            return "Keychain returned data in an unexpected format."
        }
    }
}

final class KeychainStore: HostSecretStoring {
    private let service: String

    init(service: String = "com.litespace.app.host-secrets") {
        self.service = service
    }

    func set(_ data: Data, for hostID: UUID, kind: HostSecretKind) throws {
        let query = itemQuery(hostID: hostID, kind: kind)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func data(for hostID: UUID, kind: HostSecretKind) throws -> Data? {
        var query = itemQuery(hostID: hostID, kind: kind)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.unexpectedData
        }
        return data
    }

    func delete(for hostID: UUID, kind: HostSecretKind) throws {
        let status = SecItemDelete(itemQuery(hostID: hostID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func itemQuery(hostID: UUID, kind: HostSecretKind) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(hostID.uuidString.lowercased()):\(kind.rawValue)"
        ]
    }
}
