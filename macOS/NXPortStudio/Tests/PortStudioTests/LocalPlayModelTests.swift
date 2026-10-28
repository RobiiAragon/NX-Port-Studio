import XCTest
import Foundation
import PortCore
@testable import PortStudio

private actor RelayServiceFixture: LocalDiscoveryRelaying {
    private var current = LocalDiscoveryRelaySnapshot.stopped
    private var starts = 0
    private var stops = 0
    private var heldStart: CheckedContinuation<Void, Never>?
    private let holdStart: Bool
    private let failure: LocalDiscoveryRelayError?

    init(holdStart: Bool = false, failure: LocalDiscoveryRelayError? = nil) {
        self.holdStart = holdStart
        self.failure = failure
    }
    func start() async throws -> LocalDiscoveryRelaySnapshot {
        starts += 1
        if holdStart { await withCheckedContinuation { heldStart = $0 } }
        if let failure { throw failure }
        // Deliberately ignore cancellation to exercise the model's barrier.
        current = .init(isRunning: true, interfaceCount: 1)
        return current
    }
    func stop() -> LocalDiscoveryRelaySnapshot {
        stops += 1
        current.isRunning = false
        return current
    }
    func snapshot() -> LocalDiscoveryRelaySnapshot { current }
    func counts() -> (Int, Int) { (starts, stops) }
    func release() { heldStart?.resume(); heldStart = nil }
}

@MainActor final class LocalPlayModelTests: XCTestCase {
    private func model(_ service: RelayServiceFixture) -> StudioModel {
        // Empty isolated preferences avoid reading or changing the user's account settings.
        let preferences = UserDefaults(suiteName: "org.nxnative.tests.localplay." + UUID().uuidString)!
        return StudioModel(localRelayService: service, nextendoPreferences: preferences)
    }
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Local play state did not settle"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testOpeningPageDoesNotStartBridge() async {
        let service = RelayServiceFixture()
        let model = model(service)
        model.page = .localPlay
        await model.refreshLocalDiscoveryRelay()
        XCTAssertFalse(model.localRelaySnapshot.isRunning)
        let counts = await service.counts()
        XCTAssertEqual(counts.0, 0)
        XCTAssertFalse(model.isStartingLocalRelay)
    }

    func testExplicitStartAndStopUpdateModel() async throws {
        let service = RelayServiceFixture()
        let model = model(service)
        model.startLocalDiscoveryRelay()
        model.startLocalDiscoveryRelay()
        try await eventually { !model.isStartingLocalRelay }
        XCTAssertTrue(model.localRelaySnapshot.isRunning)
        let counts = await service.counts()
        XCTAssertEqual(counts.0, 1)
        model.stopLocalDiscoveryRelay()
        try await eventually { !model.isStoppingLocalRelay }
        XCTAssertFalse(model.localRelaySnapshot.isRunning)
        XCTAssertNil(model.localRelayError)
        XCTAssertNil(model.localRelayPollTask)
    }

    func testCancelWaitsForLateStartThenStopsBeforeRestartIsAllowed() async throws {
        let service = RelayServiceFixture(holdStart: true)
        let model = model(service)
        model.startLocalDiscoveryRelay()
        try await eventually { await service.counts().0 == 1 }
        model.stopLocalDiscoveryRelay()
        XCTAssertTrue(model.isStoppingLocalRelay)
        model.startLocalDiscoveryRelay()
        let counts = await service.counts()
        XCTAssertEqual(counts.0, 1)
        await service.release()
        try await eventually { !model.isStoppingLocalRelay }
        XCTAssertFalse(model.localRelaySnapshot.isRunning)
        XCTAssertNil(model.localRelayPollTask)
        let stopped = await service.snapshot()
        XCTAssertFalse(stopped.isRunning)
    }

    func testPortConflictIsVisibleWithoutActiveOrPollingState() async throws {
        let service = RelayServiceFixture(failure: .portsInUse)
        let model = model(service)
        model.startLocalDiscoveryRelay()
        try await eventually { !model.isStartingLocalRelay }
        XCTAssertFalse(model.localRelaySnapshot.isRunning)
        XCTAssertNotNil(model.localRelayError)
        XCTAssertNil(model.localRelayPollTask)
    }
}
