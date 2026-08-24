import Foundation

public enum KnownHostDecision: Equatable, Sendable {
    case needsTrust
    case trusted
    case mismatch
}

public enum KnownHostPolicy {
    public static func evaluate(
        savedFingerprint: String?,
        presentedFingerprint: String
    ) -> KnownHostDecision {
        guard let presented = normalizedFingerprint(presentedFingerprint) else {
            return .mismatch
        }
        guard let savedFingerprint else {
            return .needsTrust
        }
        guard let saved = normalizedFingerprint(savedFingerprint) else {
            return .mismatch
        }
        return saved == presented ? .trusted : .mismatch
    }

    private static func normalizedFingerprint(_ fingerprint: String) -> String? {
        var value = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 7, value.prefix(7).lowercased() == "sha256:" {
            value.removeFirst(7)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasSuffix("=") {
            value.removeLast()
        }
        guard value.count == 43, !value.contains("=") else {
            return nil
        }
        let canonicalPaddedValue = value + "="
        guard
            let digest = Data(base64Encoded: canonicalPaddedValue),
            digest.count == 32,
            digest.base64EncodedString() == canonicalPaddedValue
        else {
            return nil
        }
        return value
    }
}
