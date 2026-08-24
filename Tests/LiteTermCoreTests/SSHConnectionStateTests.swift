import XCTest
@testable import LiteTermCore

final class SSHConnectionStateTests: XCTestCase {
    func testValidConnectionLifecycleReachesConnected() {
        var reducer = SSHConnectionStateReducer()
        let generation = reducer.beginConnection()

        XCTAssertEqual(reducer.state, .connecting)
        XCTAssertEqual(reducer.reduce(.hostKeyValidationRequired, generation: generation), true)
        XCTAssertEqual(reducer.state, .awaitingHostTrust)
        XCTAssertEqual(reducer.reduce(.hostKeyValidated, generation: generation), true)
        XCTAssertEqual(reducer.state, .authenticating)
        XCTAssertEqual(reducer.reduce(.authenticationSucceeded, generation: generation), true)
        XCTAssertEqual(reducer.state, .connected)
    }

    func testInvalidTransitionDoesNotMutateState() {
        var reducer = SSHConnectionStateReducer()
        let generation = reducer.beginConnection()

        XCTAssertEqual(reducer.reduce(.authenticationSucceeded, generation: generation), false)
        XCTAssertEqual(reducer.state, .connecting)
    }

    func testSupersededSessionCallbackIsRejected() {
        var reducer = SSHConnectionStateReducer()
        let staleGeneration = reducer.beginConnection()
        let currentGeneration = reducer.beginConnection()

        XCTAssertEqual(currentGeneration > staleGeneration, true)
        XCTAssertEqual(reducer.reduce(.hostKeyValidated, generation: staleGeneration), false)
        XCTAssertEqual(reducer.state, .connecting)
        XCTAssertEqual(reducer.reduce(.hostKeyValidated, generation: currentGeneration), true)
        XCTAssertEqual(reducer.state, .authenticating)
    }

    func testDisconnectInvalidatesInFlightCallbacks() {
        var reducer = SSHConnectionStateReducer()
        let staleGeneration = reducer.beginConnection()
        let disconnectedGeneration = reducer.disconnect()

        XCTAssertEqual(disconnectedGeneration > staleGeneration, true)
        XCTAssertEqual(reducer.state, .disconnected)
        XCTAssertEqual(reducer.reduce(.failed(.transport), generation: staleGeneration), false)
        XCTAssertEqual(reducer.state, .disconnected)
    }

    func testReconnectAttemptAdvancesGenerationAndRejectsPriorAttemptCallbacks() {
        var reducer = SSHConnectionStateReducer()
        let priorGeneration = reducer.beginConnection()
        XCTAssertEqual(reducer.reduce(.hostKeyValidated, generation: priorGeneration), true)
        XCTAssertEqual(reducer.reduce(.authenticationSucceeded, generation: priorGeneration), true)

        let reconnectGeneration = reducer.beginReconnect(attempt: 1)
        XCTAssertEqual(reconnectGeneration > priorGeneration, true)
        XCTAssertEqual(reducer.state, .reconnecting(attempt: 1))
        XCTAssertEqual(reducer.reduce(.failed(.transport), generation: priorGeneration), false)
        XCTAssertEqual(reducer.reduce(.hostKeyValidated, generation: reconnectGeneration), true)
        XCTAssertEqual(reducer.state, .authenticating)
    }

    func testReconnectOrchestratorUsesExactlyThreeForegroundDelays() {
        var orchestrator = SSHReconnectOrchestrator(isEnabled: true)
        orchestrator.userInitiatedConnection()
        orchestrator.connectionEstablished()

        XCTAssertEqual(
            orchestrator.connectionFailed(.transportLoss),
            SSHReconnectDirective(attempt: 1, delay: .seconds(1))
        )
        XCTAssertEqual(
            orchestrator.connectionFailed(.transportLoss),
            SSHReconnectDirective(attempt: 2, delay: .seconds(2))
        )
        XCTAssertEqual(
            orchestrator.connectionFailed(.transportLoss),
            SSHReconnectDirective(attempt: 3, delay: .seconds(4))
        )
        XCTAssertNil(orchestrator.connectionFailed(.transportLoss))
    }

    func testManualDisconnectAndSecurityFailuresCancelReconnectIntent() {
        for failure in [
            SSHConnectionFailure.manualDisconnect,
            .authenticationRejected,
            .hostKeyMismatch
        ] {
            var orchestrator = SSHReconnectOrchestrator(isEnabled: true)
            orchestrator.userInitiatedConnection()

            XCTAssertNil(orchestrator.connectionFailed(failure))
            XCTAssertNil(orchestrator.scenePhaseChanged(isActive: false))
            XCTAssertNil(orchestrator.scenePhaseChanged(isActive: true))
            XCTAssertEqual(orchestrator.wantsConnection, false)
        }
    }

    func testInactiveSceneCancelsRetryAndActiveSceneRestartsOnlyWantedConnection() {
        var orchestrator = SSHReconnectOrchestrator(isEnabled: true)
        orchestrator.userInitiatedConnection()
        orchestrator.connectionEstablished()

        XCTAssertNil(orchestrator.scenePhaseChanged(isActive: false))
        XCTAssertNil(orchestrator.connectionFailed(.transportLoss))
        XCTAssertEqual(
            orchestrator.scenePhaseChanged(isActive: true),
            SSHReconnectDirective(attempt: 1, delay: .seconds(1))
        )

        orchestrator.manualDisconnect()
        XCTAssertNil(orchestrator.scenePhaseChanged(isActive: false))
        XCTAssertNil(orchestrator.scenePhaseChanged(isActive: true))
    }

    func testDisabledHostNeverSchedulesForegroundReconnect() {
        var orchestrator = SSHReconnectOrchestrator(isEnabled: false)
        orchestrator.userInitiatedConnection()
        orchestrator.connectionEstablished()

        XCTAssertNil(orchestrator.connectionFailed(.transportLoss))
        XCTAssertNil(orchestrator.scenePhaseChanged(isActive: false))
        XCTAssertNil(orchestrator.scenePhaseChanged(isActive: true))
    }
}
