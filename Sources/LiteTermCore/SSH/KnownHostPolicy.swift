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
        guard let savedFingerprint else {
            return .needsTrust
        }
        guard
            let saved = normalizedFingerprint(savedFingerprint),
            let presented = normalizedFingerprint(presentedFingerprint)
        else {
            return .mismatch
        }
        return saved == presented ? .trusted : .mismatch
    }

    private static func normalizedFingerprint(_ fingerprint: String) -> String? {
        var value = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 7, value.prefix(7).lowercased() == "sha256:" {
            value.removeFirst(7)
        }
        if value.hasSuffix("==") {
            value.removeLast(2)
        } else if value.hasSuffix("=") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }
}
