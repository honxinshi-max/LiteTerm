import Foundation

public struct ReadyPortLease: Equatable, Sendable {
    public let generation: UInt64
    public let port: Int
    public let listenerID: UUID
    public let runtimeID: UUID
    public let secretHandle: UUID
    public let healthExpiresAt: Date

    public init(
        generation: UInt64,
        port: Int,
        listenerID: UUID,
        runtimeID: UUID,
        secretHandle: UUID,
        healthExpiresAt: Date
    ) {
        self.generation = generation
        self.port = port
        self.listenerID = listenerID
        self.runtimeID = runtimeID
        self.secretHandle = secretHandle
        self.healthExpiresAt = healthExpiresAt
    }
}

public struct ReadyPortLeasePolicy: Sendable {
    public init() {}

    public func isPublishable(
        _ lease: ReadyPortLease,
        currentGeneration: UInt64,
        listenerID: UUID?,
        runtimeID: UUID?,
        listenerIsActive: Bool,
        runtimeIsAlive: Bool,
        now: Date
    ) -> Bool {
        (1...65_535).contains(lease.port)
            && lease.generation == currentGeneration
            && lease.listenerID == listenerID
            && lease.runtimeID == runtimeID
            && listenerIsActive
            && runtimeIsAlive
            && lease.healthExpiresAt > now
    }
}
