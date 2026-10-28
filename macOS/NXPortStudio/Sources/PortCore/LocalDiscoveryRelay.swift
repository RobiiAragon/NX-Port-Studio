import Foundation
import CLANRelay
import Darwin

public enum LocalDiscoveryRelayError: Error, LocalizedError, Sendable, Equatable {
    case portsInUse
    case noLocalNetwork
    case permissionDenied
    case outOfMemory
    case invalidConfiguration
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .portsInUse: "UDP port 30000 or 11452 is already in use. Close the other local discovery bridge or game using these ports, then try again."
        case .noLocalNetwork: "No eligible local network interface was found. Connect this Mac to the same network as your devices, then try again."
        case .permissionDenied: "Local Network access was denied. Allow NX Port Studio in System Settings → Privacy & Security → Local Network, then try again."
        case .outOfMemory: "The local discovery bridge could not allocate its working memory."
        case .invalidConfiguration: "The local discovery bridge configuration is invalid."
        case .system: "The local discovery bridge encountered a network error."
        }
    }
}

public struct LocalDiscoveryRelaySnapshot: Sendable, Equatable {
    public var isRunning: Bool
    public var interfaceCount: Int
    public var activeQueries: Int
    public var queriesReceived: UInt64
    public var queriesForwarded: UInt64
    public var responsesForwarded: UInt64
    public var packetsDropped: UInt64
    public var queriesExpired: UInt64
    public var queriesRateLimited: UInt64
    public var failure: LocalDiscoveryRelayError?

    public static let stopped = LocalDiscoveryRelaySnapshot()

    public init(isRunning: Bool = false, interfaceCount: Int = 0, activeQueries: Int = 0,
                queriesReceived: UInt64 = 0, queriesForwarded: UInt64 = 0,
                responsesForwarded: UInt64 = 0, packetsDropped: UInt64 = 0,
                queriesExpired: UInt64 = 0, queriesRateLimited: UInt64 = 0,
                failure: LocalDiscoveryRelayError? = nil) {
        self.isRunning = isRunning
        self.interfaceCount = interfaceCount
        self.activeQueries = activeQueries
        self.queriesReceived = queriesReceived
        self.queriesForwarded = queriesForwarded
        self.responsesForwarded = responsesForwarded
        self.packetsDropped = packetsDropped
        self.queriesExpired = queriesExpired
        self.queriesRateLimited = queriesRateLimited
        self.failure = failure
    }

    func afterStopping() -> Self {
        var value = self
        value.isRunning = false
        value.activeQueries = 0
        value.failure = nil
        return value
    }
}

/// Creation and snapshots never open sockets. Only an explicit start does so.
public protocol LocalDiscoveryRelaying: Sendable {
    func start() async throws -> LocalDiscoveryRelaySnapshot
    func stop() async -> LocalDiscoveryRelaySnapshot
    func snapshot() async -> LocalDiscoveryRelaySnapshot
}

protocol LocalDiscoveryRelayDriving: Sendable {
    func start() throws -> LocalDiscoveryRelaySnapshot
    func stop() -> LocalDiscoveryRelaySnapshot
    func snapshot() -> LocalDiscoveryRelaySnapshot
}

public actor LocalDiscoveryRelayService: LocalDiscoveryRelaying {
    private let driver: any LocalDiscoveryRelayDriving

    public init() { driver = NativeLocalDiscoveryRelayDriver() }
    init(driver: any LocalDiscoveryRelayDriving) { self.driver = driver }

    public func start() throws -> LocalDiscoveryRelaySnapshot {
        try Task.checkCancellation()
        let value = try driver.start()
        do { try Task.checkCancellation() }
        catch {
            _ = driver.stop()
            throw error
        }
        return value
    }

    public func stop() -> LocalDiscoveryRelaySnapshot { driver.stop() }
    public func snapshot() -> LocalDiscoveryRelaySnapshot { driver.snapshot() }
}

/// The C lifetime is serialized both by the actor and this lock, including deinit.
private final class NativeLocalDiscoveryRelayDriver: LocalDiscoveryRelayDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var last = LocalDiscoveryRelaySnapshot.stopped

    deinit { if let handle { dm_lan_relay_stop(handle) } }

    func start() throws -> LocalDiscoveryRelaySnapshot {
        try lock.withLock {
            if let existing = handle {
                let current = snapshotLocked()
                if current.isRunning { return current }
                dm_lan_relay_stop(existing)
                handle = nil
            }
            var raw = dm_lan_relay_snapshot()
            let status = dm_lan_relay_start(nil, &handle, &raw)
            guard status == DM_LAN_RELAY_OK else {
                handle = nil
                let error = Self.failure(status: status, system: raw.system_errno)
                last = LocalDiscoveryRelaySnapshot(failure: error)
                throw error
            }
            return snapshotLocked()
        }
    }

    func stop() -> LocalDiscoveryRelaySnapshot {
        lock.withLock {
            if let handle {
                _ = snapshotLocked()
                dm_lan_relay_stop(handle)
                self.handle = nil
            }
            last = last.afterStopping()
            return last
        }
    }

    func snapshot() -> LocalDiscoveryRelaySnapshot { lock.withLock { snapshotLocked() } }

    private func snapshotLocked() -> LocalDiscoveryRelaySnapshot {
        guard let handle else { return last }
        var raw = dm_lan_relay_snapshot()
        dm_lan_relay_snapshot_get(handle, &raw)
        let status = dm_lan_relay_status(rawValue: raw.status)
        last = .init(isRunning: raw.running != 0, interfaceCount: Int(raw.interfaces),
                     activeQueries: Int(raw.active_queries), queriesReceived: raw.queries,
                     queriesForwarded: raw.fanout, responsesForwarded: raw.replies,
                     packetsDropped: raw.rejected, queriesExpired: raw.expired,
                     queriesRateLimited: raw.rate_limited,
                     failure: status == DM_LAN_RELAY_OK ? nil : Self.failure(status: status, system: raw.system_errno))
        return last
    }

    private static func failure(status: dm_lan_relay_status, system: UInt32) -> LocalDiscoveryRelayError {
        switch status {
        case DM_LAN_RELAY_PORT_BUSY: return .portsInUse
        case DM_LAN_RELAY_NO_INTERFACE: return .noLocalNetwork
        case DM_LAN_RELAY_NO_MEMORY: return .outOfMemory
        case DM_LAN_RELAY_INVALID: return .invalidConfiguration
        default:
            let code = Int32(bitPattern: system)
            return code == EACCES || code == EPERM ? .permissionDenied : .system(code)
        }
    }
}
