import Crypto
import Foundation
import LiteTermCore
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

enum SSHHostTrustKind: Equatable, Sendable {
    case firstUse
    case replacement
}

enum SSHHostKeyValidationError: Error, Sendable {
    case invalidPublicKeyRepresentation
    case hostKeyMismatch
    case credentialUnavailable
    case trustCancelled
    case validationSuperseded
}

final class SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private struct PendingValidation {
        let fingerprint: String
        let promise: EventLoopPromise<Void>
    }

    private struct State {
        var storedFingerprint: SSHStoredHostFingerprint
        var pending: PendingValidation?
    }

    private let state: NIOLockedValueBox<State>
    private let onTrustRequired: @Sendable (String, SSHHostTrustKind) -> Void
    private let onValidated: @Sendable () -> Void

    init(
        storedFingerprint: SSHStoredHostFingerprint,
        onTrustRequired: @escaping @Sendable (String, SSHHostTrustKind) -> Void,
        onValidated: @escaping @Sendable () -> Void
    ) {
        state = NIOLockedValueBox(State(storedFingerprint: storedFingerprint, pending: nil))
        self.onTrustRequired = onTrustRequired
        self.onValidated = onValidated
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint: String
        do {
            fingerprint = try Self.openSSHSHA256Fingerprint(for: hostKey)
        } catch {
            validationCompletePromise.fail(error)
            return
        }

        let decision = state.withLockedValue { state in
            switch state.storedFingerprint {
            case .absent:
                return KnownHostPolicy.evaluate(
                    savedFingerprint: nil,
                    presentedFingerprint: fingerprint
                )
            case .valid(let savedFingerprint):
                return KnownHostPolicy.evaluate(
                    savedFingerprint: savedFingerprint,
                    presentedFingerprint: fingerprint
                )
            case .corrupt:
                return .mismatch
            }
        }

        switch decision {
        case .trusted:
            onValidated()
            validationCompletePromise.succeed(())

        case .needsTrust, .mismatch:
            let replacedPromise = state.withLockedValue { state -> EventLoopPromise<Void>? in
                let replaced = state.pending?.promise
                state.pending = PendingValidation(
                    fingerprint: fingerprint,
                    promise: validationCompletePromise
                )
                return replaced
            }
            replacedPromise?.fail(SSHHostKeyValidationError.validationSuperseded)
            onTrustRequired(
                fingerprint,
                decision == .needsTrust ? .firstUse : .replacement
            )
        }
    }

    func confirmPendingTrust() {
        let pending = state.withLockedValue { state -> PendingValidation? in
            guard let pending = state.pending else { return nil }
            state.pending = nil
            state.storedFingerprint = .valid(pending.fingerprint)
            return pending
        }
        guard let pending else { return }
        onValidated()
        pending.promise.succeed(())
    }

    func rejectPendingTrust(as failure: SSHClientFailure) {
        let pending = state.withLockedValue { state -> PendingValidation? in
            defer { state.pending = nil }
            return state.pending
        }
        guard let pending else { return }
        switch failure {
        case .hostKeyMismatch:
            pending.promise.fail(SSHHostKeyValidationError.hostKeyMismatch)
        case .credentialUnavailable:
            pending.promise.fail(SSHHostKeyValidationError.credentialUnavailable)
        default:
            pending.promise.fail(SSHHostKeyValidationError.trustCancelled)
        }
    }

    func cancelPendingValidation() {
        rejectPendingTrust(as: .trustCancelled)
    }

    static func openSSHSHA256Fingerprint(for hostKey: NIOSSHPublicKey) throws -> String {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        let fields = openSSHKey.split(separator: " ", maxSplits: 2)
        guard
            fields.count >= 2,
            let wireBlob = Data(base64Encoded: String(fields[1]))
        else {
            throw SSHHostKeyValidationError.invalidPublicKeyRepresentation
        }
        let digest = Data(SHA256.hash(data: wireBlob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
