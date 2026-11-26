// A Mac port's side of NX Port Studio's Nextendo agent (docs/nextendo-agent.md).
// When the agent answers, it owns the account: this port reads no Keychain item
// and runs no renewal; the host gets the record through its credential provider.
// The account API (me, friends, presence) also goes through the agent, which holds
// the OAuth grant: the port's record has none. When the agent does not answer (not
// installed, not running, this build not registered, an older agent), the host
// keeps its own path (GameAccount.swift) unchanged.
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
        let outcome = Once<(status: NextendoAgentStatus, record: Data?, generation: UInt64)>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finished.signal() }
        guard let service = proxy as? NextendoAgentPortService else { connection.invalidate(); return false }
        service.hello(NextendoAgent.protocolVersion, titleID: title, gameVersion: version) { status, _ in
            guard NextendoAgentStatus(wire: status) == .ok else { outcome.set((.versionMismatch, nil, 0)); finished.signal(); return }
            service.gameCredential(renew: true) { status, record, generation in
                outcome.set((NextendoAgentStatus(wire: status), record, generation)); finished.signal()
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

    /// The host's account API transport: one request made by the agent with its grant.
    /// Blocks the calling guest thread (the host marks it waiting) for at most `timeout`.
    func request(_ resource: String, body: Data?, timeout: TimeInterval = 15) -> (status: NextendoAgentStatus, http: Int, body: Data?) {
        guard let connection = lock.withLock({ self.connection }) else { return (.unavailable, 0, nil) }
        let finished = DispatchSemaphore(value: 0)
        let outcome = Once<(status: NextendoAgentStatus, http: Int, body: Data?)>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finished.signal() }
        guard let service = proxy as? NextendoAgentPortService else { return (.unavailable, 0, nil) }
        service.social(resource, body: body) { status, http, body in
            outcome.set((NextendoAgentStatus(wire: status), http, body)); finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success, let result = outcome.value else { return (.unavailable, 0, nil) }
        return result
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

    /// The first reply wins; a late one after a timeout is dropped.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: T?
        func set(_ value: T) { lock.withLock { if stored == nil { stored = value } } }
        var value: T? { lock.withLock { stored } }
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

/// The host's account API provider (`dm_nextendo_set_api_provider`). True when the
/// request reached Nextendo, whatever its HTTP status; the host checks the status.
@_cdecl("dm_mac_agent_api")
public func dmMacAgentAPI(_ resource: UnsafePointer<CChar>?, _ body: UnsafePointer<UInt8>?, _ bodySize: Int,
                          _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
                          _ size: UnsafeMutablePointer<Int>?, _ status: UnsafeMutablePointer<UInt32>?) -> Bool {
    guard let resource, let output, let size, let status, capacity > 0,
          bodySize >= 0, bodySize <= NextendoAgent.presenceLimit, bodySize == 0 || body != nil else { return false }
    size.pointee = 0; status.pointee = 0
    let data = bodySize > 0 ? body.map { Data(bytes: $0, count: bodySize) } : nil
    let result = MacAgentClient.shared.request(String(cString: resource), body: data)
    guard result.status == .ok, (100...599).contains(result.http) else { return false }
    status.pointee = UInt32(result.http)
    guard let reply = result.body else { return true }
    guard reply.count <= capacity else { return false }
    reply.copyBytes(to: output, count: reply.count); size.pointee = reply.count
    return true
}
