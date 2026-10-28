import XCTest
@testable import PortCore

private final class RelayDriverFixture: LocalDiscoveryRelayDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var current = LocalDiscoveryRelaySnapshot.stopped
    private var starts = 0
    private var stops = 0
    var startFailure: LocalDiscoveryRelayError?
    var cancelDuringStart = false

    func start() throws -> LocalDiscoveryRelaySnapshot {
        try lock.withLock {
            if current.isRunning { return current }
            starts += 1
            if let startFailure { throw startFailure }
            current = .init(isRunning: true, interfaceCount: 1)
            if cancelDuringStart { withUnsafeCurrentTask { $0?.cancel() } }
            return current
        }
    }
    func stop() -> LocalDiscoveryRelaySnapshot {
        lock.withLock {
            if current.isRunning { stops += 1 }
            current = current.afterStopping()
            return current
        }
    }
    func snapshot() -> LocalDiscoveryRelaySnapshot { lock.withLock { current } }
    func counts() -> (Int, Int) { lock.withLock { (starts, stops) } }
    func recordTraffic() {
        lock.withLock { current.queriesReceived = 2; current.queriesForwarded = 24; current.responsesForwarded = 1 }
    }
}

@MainActor final class LocalDiscoveryRelayTests: XCTestCase {
    func testPackagedStudioDeclaresLocalNetworkUsageWithoutBonjour() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: package.appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)
        let plist = try XCTUnwrap(script.components(separatedBy: "<<'PLIST'\n").dropFirst().first?.components(separatedBy: "\nPLIST").first)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        let description = try XCTUnwrap(values["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertTrue(description.contains("local network"))
        XCTAssertTrue(description.contains("discovery"))
        XCTAssertNil(values["NSBonjourServices"])
    }

    func testCreationAndSnapshotNeverStartNetworking() async {
        let driver = RelayDriverFixture()
        let service = LocalDiscoveryRelayService(driver: driver)
        let value = await service.snapshot()
        XCTAssertEqual(value, .stopped)
        XCTAssertEqual(driver.counts().0, 0)
        // The production driver's cold snapshot also performs no socket action.
        let native = LocalDiscoveryRelayService()
        let initial = await native.snapshot()
        XCTAssertEqual(initial, .stopped)
    }

    func testStartTrafficAndStopPreserveCountersWithNoAutomaticRestart() async throws {
        let driver = RelayDriverFixture()
        let service = LocalDiscoveryRelayService(driver: driver)
        let started = try await service.start()
        XCTAssertTrue(started.isRunning)
        _ = try await service.start()
        XCTAssertEqual(driver.counts().0, 1)
        driver.recordTraffic()
        let traffic = await service.snapshot()
        XCTAssertEqual(traffic.queriesReceived, 2)
        XCTAssertEqual(traffic.queriesForwarded, 24)
        XCTAssertEqual(traffic.responsesForwarded, 1)
        let stopped = await service.stop()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stopped.responsesForwarded, 1)
        _ = await service.stop()
        XCTAssertEqual(driver.counts().1, 1)
        let later = await service.snapshot()
        XCTAssertEqual(later, stopped)
        XCTAssertEqual(driver.counts().0, 1)
    }

    func testTypedPortConflictDoesNotReportAnActiveBridge() async {
        let driver = RelayDriverFixture()
        driver.startFailure = .portsInUse
        let service = LocalDiscoveryRelayService(driver: driver)
        do { _ = try await service.start(); XCTFail("Expected port conflict") }
        catch { XCTAssertEqual(error as? LocalDiscoveryRelayError, .portsInUse) }
        let value = await service.snapshot()
        XCTAssertFalse(value.isRunning)
        XCTAssertEqual(driver.counts().0, 1)
    }

    func testCancelledStartDoesNotOpenDriver() async {
        let driver = RelayDriverFixture()
        let service = LocalDiscoveryRelayService(driver: driver)
        let task = Task { try await service.start() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.counts().0, 0)
    }

    func testCancellationAfterNativeStartClosesTheNewHandle() async {
        let driver = RelayDriverFixture()
        driver.cancelDuringStart = true
        let service = LocalDiscoveryRelayService(driver: driver)
        let task = Task { try await service.start() }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.counts().0, 1)
        XCTAssertEqual(driver.counts().1, 1)
        let value = await service.snapshot()
        XCTAssertFalse(value.isRunning)
    }
}
