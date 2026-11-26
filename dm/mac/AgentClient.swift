// A Mac port's side of NX Port Studio's Nextendo agent (docs/nextendo-agent.md).
// When the agent answers, it owns the account: this port reads no Keychain item
// and runs no renewal; the host gets the record through its credential provider.
// When it does not answer (not installed, not running, this build not registered),
// the host keeps its own path (GameAccount.swift) unchanged.
import Foundation

final class MacAgentClient: NSObject, NextendoAgentListener, @unchecked Sendable {
    static let shared = MacAgentClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var record: Data?
    private var generation: UInt64 = 0
    private var invalidate: (@convention(c) () -> Void)?

    /// Called once on the guest worker, before the SDK. Blocks for at most `timeout`.
    func prepare(invalidate: @escaping @convention(c) () -> Void, timeout: TimeInterval = 5) -> Bool {
        guard !Thread.isMainThread else { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        let title = info["DMTitleID"] as? String ?? "", version = info["CFBundleShortVersionString"] as? String ?? ""
        let connection = NSXPCConnection(machServiceName: NextendoAgent.portService)
        connection.remoteObjectInterface = NextendoAgentInterfaces.port()
        connection.exportedInterface = NextendoAgentInterfaces.listener()
        connection.exportedObject = self
        connection.resume()
        let finished = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finished.signal() }
        guard let service = proxy as? NextendoAgentPortService else { connection.invalidate(); return false }
        service.hello(NextendoAgent.protocolVersion, titleID: title, gameVersion: version) { status, _ in
            guard NextendoAgentStatus(wire: status) == .ok else { outcome.set(.versionMismatch, nil, 0); finished.signal(); return }
            service.gameCredential(renew: true) { status, record, generation in
                outcome.set(NextendoAgentStatus(wire: status), record, generation); finished.signal()
            }
        }
        guard finished.wait(timeout: .now() + timeout) == .success, let result = outcome.value else {
            connection.invalidate(); fputs("[RED] launcher: the Nextendo agent is not available to this port (not running, or this build is not registered); it signs in by itself\n", stderr); return false
        }
        switch result.status {
        case .ok:
            guard let data = result.record, (try? NextendoSession.decodeForPort(data)) != nil else { break }
            lock.withLock { self.connection = connection; record = data; generation = result.generation; self.invalidate = invalidate }
            return true
        case .signedOut:
            // The agent is the owner and the account is signed out: no fallback to the Keychain.
            lock.withLock { self.connection = connection; record = nil; generation = result.generation; self.invalidate = invalidate }
            return true
        default: break
        }
        connection.invalidate()
        fputs("[RED] launcher: the Nextendo agent refused this port (status \(result.status.rawValue)); this port signs in by itself\n", stderr)
        return false
    }

    /// The host's credential provider: the cached record, never a storage read.
    func copyRecord(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int, size: UnsafeMutablePointer<Int>) -> Bool {
        lock.withLock {
            guard let record, record.count <= capacity else { return false }
            record.copyBytes(to: buffer, count: record.count); size.pointee = record.count; return true
        }
    }

    /// Studio changed the account: fetch the current record without a new renewal, then
    /// let the host drop what it captured from the old one.
    func accountChanged(_ generation: UInt64) {
        let current: (NSXPCConnection?, UInt64) = lock.withLock { (connection, self.generation) }
        guard let connection = current.0, generation > current.1,
              let service = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? NextendoAgentPortService else { return }
        service.gameCredential(renew: false) { [weak self] status, record, latest in
            guard let self else { return }
            let accepted = NextendoAgentStatus(wire: status) == .ok ? record.flatMap { (try? NextendoSession.decodeForPort($0)) != nil ? $0 : nil } : nil
            let callback: (@convention(c) () -> Void)? = self.lock.withLock {
                guard latest >= self.generation else { return nil }
                self.record = accepted; self.generation = latest; return self.invalidate
            }
            callback?()
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock(); private var stored: (status: NextendoAgentStatus, record: Data?, generation: UInt64)?
        func set(_ status: NextendoAgentStatus, _ record: Data?, _ generation: UInt64) { lock.withLock { if stored == nil { stored = (status, record, generation) } } }
        var value: (status: NextendoAgentStatus, record: Data?, generation: UInt64)? { lock.withLock { stored } }
    }
}

@_cdecl("dm_mac_agent_prepare")
public func dmMacAgentPrepare(_ invalidate: @escaping @convention(c) () -> Void) -> Bool {
    MacAgentClient.shared.prepare(invalidate: invalidate)
}

@_cdecl("dm_mac_agent_credential")
public func dmMacAgentCredential(_ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int, _ size: UnsafeMutablePointer<Int>?) -> Bool {
    guard let buffer, let size, capacity > 0 else { return false }
    return MacAgentClient.shared.copyRecord(into: buffer, capacity: capacity, size: size)
}
