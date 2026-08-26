import NIOCore
import NIOSSH

enum SSHAuthenticationDelegateError: Error, Sendable {
    case methodUnavailable
    case authenticationRejected
}

final class SSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var credential: SSHClientCredential?

    init(username: String, credential: SSHClientCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let credential else {
            nextChallengePromise.fail(SSHAuthenticationDelegateError.authenticationRejected)
            return
        }
        self.credential = nil

        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHAuthenticationDelegateError.methodUnavailable)
                return
            }
            offer = .password(.init(password: password))

        case .generatedKey(let privateKey):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHAuthenticationDelegateError.methodUnavailable)
                return
            }
            offer = .privateKey(.init(privateKey: privateKey))
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: offer
            )
        )
    }
}
