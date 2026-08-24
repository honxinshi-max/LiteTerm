import Foundation

public enum SSHConnectionFailure: Equatable, Sendable {
    case transportLoss
    case authenticationRejected
    case hostKeyMismatch
    case manualDisconnect
}

public struct ReconnectPolicy: Sendable {
    private let isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func nextDelay(
        afterAttempt attempt: Int,
        failure: SSHConnectionFailure,
        sceneIsActive: Bool
    ) -> Duration? {
        guard isEnabled, sceneIsActive, failure == .transportLoss else {
            return nil
        }
        switch attempt {
        case 0:
            return .seconds(1)
        case 1:
            return .seconds(2)
        case 2:
            return .seconds(4)
        default:
            return nil
        }
    }
}
