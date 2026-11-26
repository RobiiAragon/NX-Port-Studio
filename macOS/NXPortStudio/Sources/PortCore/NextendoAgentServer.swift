// The Mac Nextendo agent: one owner of the stored account for every native port
// (docs/nextendo-agent.md). Studio and the agent executable use this file; ports
// only compile the contract in NextendoAgent.swift.
import Foundation
import os
import Security

private let agentLog = Logger(subsystem: "org.nxnative.portstudio.agent", category: "agent")

// MARK: Code identity

public enum NextendoAgentCode {
    /// The cdhash macOS reports for a signed bundle or executable on disk.
    public static func cdhash(of url: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw NextendoError.authorizationUnavailable }
        return try cdhash(of: code)
    }
    /// The running process's own cdhash.
    public static func ownCDHash() throws -> Data {
        var running: SecCode?, code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { throw NextendoError.authorizationUnavailable }
        return try cdhash(of: code)
    }
    private static func cdhash(of code: SecStaticCode) throws -> Data {
        // Validate the signature first: a broken or unsigned bundle has no identity to trust.
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw NextendoError.authorizationUnavailable }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let values = info as? [String: Any], let unique = values[kSecCodeInfoUnique as String] as? Data,
              valid(unique) else { throw NextendoError.authorizationUnavailable }
        return unique
    }
    public static func valid(_ cdhash: Data) -> Bool { cdhash.count == 20 }
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    public static func data(hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count == 40 else { return nil }
        var out = Data(capacity: 20)
        for i in stride(from: 0, to: 40, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
    /// A code-signing requirement that matches exactly these code directories, or nil for none.
    public static func requirement(for cdhashes: [Data]) -> String? {
        let terms = cdhashes.filter(valid).map { "cdhash H\"\(hex($0))\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " or ")
    }
}

// MARK: Registered ports

public protocol NextendoAgentPeerStore: Sendable {
    func load() throws -> [Data]
    func save(_ peers: [Data]) throws
}

/// The allowlist lives in a Keychain item the agent creates, so another process
/// cannot add itself without macOS asking. A plain file would not give that.
public struct NextendoAgentKeychainPeerStore: NextendoAgentPeerStore {
    public static let service = "org.nxnative.portstudio.agent.peers"
    public static let account = "ports"
    public init() {}
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                      kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false] }
    public func load() throws -> [Data] {
        var values = query; values[kSecReturnData as String] = true; values[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(values as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 65_536,
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { throw NextendoError.keychain(status) }
        return list.compactMap(NextendoAgentCode.data(hex:))
    }
    public func save(_ peers: [Data]) throws {
        let data = try JSONSerialization.data(withJSONObject: peers.map(NextendoAgentCode.hex))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query; values[kSecValueData as String] = data
            values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(values as CFDictionary, nil)
            guard added == errSecSuccess else { throw NextendoError.keychain(added) }
        } else if status != errSecSuccess { throw NextendoError.keychain(status) }
    }
}

public final class NextendoAgentMemoryPeerStore: NextendoAgentPeerStore, @unchecked Sendable {
    private let lock = NSLock(); private var peers: [Data]
    public init(_ peers: [Data] = []) { self.peers = peers }
    public func load() throws -> [Data] { lock.withLock { peers } }
    public func save(_ peers: [Data]) throws { lock.withLock { self.peers = peers } }
}

final class NextendoAgentPeers: @unchecked Sendable {
    private let lock = NSLock(), store: any NextendoAgentPeerStore
    private var peers: [Data]
    init(store: any NextendoAgentPeerStore) {
        self.store = store
        do { peers = try store.load() } catch { peers = []; agentLog.error("peer list unreadable; ports must be registered again") }
    }
    var count: Int { lock.withLock { peers.count } }
    var requirement: String? { lock.withLock { NextendoAgentCode.requirement(for: peers) } }
    /// Most recent last; a rebuilt port adds its new cdhash and the oldest entries fall off.
    func register(_ cdhash: Data) throws {
        guard NextendoAgentCode.valid(cdhash) else { throw NextendoError.invalidResponse }
        try lock.withLock {
            var next = peers.filter { $0 != cdhash }; next.append(cdhash)
            if next.count > NextendoAgent.peerLimit { next.removeFirst(next.count - NextendoAgent.peerLimit) }
            try store.save(next); peers = next
        }
    }
}

// MARK: Account

/// Owns renewal for every port that connects. Studio still signs in and out
/// itself and reports each change, which bumps the generation pushed to ports.
public actor NextendoAgentAccount {
    private let service: NextendoAccountService
    private let store: any NextendoCredentialStore
    private let now: @Sendable () -> Date
    public private(set) var generation: UInt64 = 1
    public init(store: any NextendoCredentialStore = NextendoKeychainStore(), http: any NextendoHTTPClient = NextendoURLSessionClient(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.now = now
        service = NextendoAccountService(store: store, http: http, now: now)
    }
    public func credential(renew: Bool) async -> (status: NextendoAgentStatus, record: Data?, generation: UInt64) {
        if renew {
            // Same policy as a port's own boot (dm/mac/GameAccount.swift): a failed
            // renewal keeps the stored record, which the host validates again.
            do { _ = try await service.prepareGameAccount(forceGameRefresh: true) }
            catch is CancellationError { return (.failed, nil, generation) }
            catch { agentLog.error("game account preparation failed; the stored account is used") }
        }
        let session: NextendoSession?
        do { session = try store.load() } catch { return (.unavailable, nil, generation) }
        guard let session else { return (.signedOut, nil, generation) }
        guard session.tokenKind == .nex, !session.summary(at: now()).isExpired,
              let record = try? session.encodedForPort(), record.count <= NextendoAgent.credentialLimit else { return (.unavailable, nil, generation) }
        return (.ok, record, generation)
    }
    public func accountDidChange() -> UInt64 { generation &+= 1; return generation }
}

// MARK: XPC

public final class NextendoAgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let portListener: NSXPCListener, adminListener: NSXPCListener
    let account: NextendoAgentAccount
    let peers: NextendoAgentPeers
    private let adminRequirement: String?
    private let lock = NSLock()
    private var ports: [ObjectIdentifier: NSXPCConnection] = [:]

    /// `adminRequirement` nil refuses every administrator; a port is accepted only
    /// when its code matches a registered cdhash.
    public init(portListener: NSXPCListener, adminListener: NSXPCListener, account: NextendoAgentAccount,
                peerStore: any NextendoAgentPeerStore, adminRequirement: String?) {
        self.portListener = portListener; self.adminListener = adminListener; self.account = account
        peers = NextendoAgentPeers(store: peerStore); self.adminRequirement = adminRequirement
        super.init()
        portListener.delegate = self; adminListener.delegate = self
    }

    /// The launchd agent inside NX Port Studio.app: its administrator is exactly that app.
    public static func launchd() -> NextendoAgentServer {
        let app = Bundle.main.bundleURL
        var requirement: String?
        if app.pathExtension == "app", let studio = try? NextendoAgentCode.cdhash(of: app) { requirement = NextendoAgentCode.requirement(for: [studio]) }
        else { agentLog.error("not inside a signed NX Port Studio.app; administration is refused") }
        return NextendoAgentServer(portListener: NSXPCListener(machServiceName: NextendoAgent.portService),
                                   adminListener: NSXPCListener(machServiceName: NextendoAgent.adminService),
                                   account: NextendoAgentAccount(), peerStore: NextendoAgentKeychainPeerStore(), adminRequirement: requirement)
    }

    public func resume() { portListener.resume(); adminListener.resume() }
    public var connectedPorts: Int { lock.withLock { ports.count } }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if listener === adminListener {
            guard let adminRequirement else { return false }
            connection.setCodeSigningRequirement(adminRequirement)
            connection.exportedInterface = NextendoAgentInterfaces.admin()
            connection.exportedObject = NextendoAgentAdminSession(server: self)
            connection.resume(); return true
        }
        guard listener === portListener else { return false }
        guard let requirement = peers.requirement else { agentLog.notice("port refused: no registered ports"); return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NextendoAgentInterfaces.port()
        connection.exportedObject = NextendoAgentPortSession(server: self)
        connection.remoteObjectInterface = NextendoAgentInterfaces.listener()
        let key = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in self?.lock.withLock { _ = self?.ports.removeValue(forKey: key) } }
        lock.withLock { ports[key] = connection }
        connection.resume(); return true
    }

    func push(_ generation: UInt64) {
        let connected = lock.withLock { Array(ports.values) }
        for connection in connected {
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? NextendoAgentListener)?.accountChanged(generation)
        }
    }
}

final class NextendoAgentPortSession: NSObject, NextendoAgentPortService, @unchecked Sendable {
    private weak var server: NextendoAgentServer?
    init(server: NextendoAgentServer) { self.server = server }
    func hello(_ version: Int, titleID: String, gameVersion: String, reply: @escaping @Sendable (Int, Int) -> Void) {
        let status: NextendoAgentStatus = version == NextendoAgent.protocolVersion ? .ok : .versionMismatch
        reply(status.rawValue, NextendoAgent.protocolVersion)
    }
    func gameCredential(renew: Bool, reply: @escaping @Sendable (Int, Data?, UInt64) -> Void) {
        guard let account = server?.account else { reply(NextendoAgentStatus.unavailable.rawValue, nil, 0); return }
        Task { let result = await account.credential(renew: renew); reply(result.status.rawValue, result.record, result.generation) }
    }
}

final class NextendoAgentAdminSession: NSObject, NextendoAgentAdminService, @unchecked Sendable {
    private weak var server: NextendoAgentServer?
    init(server: NextendoAgentServer) { self.server = server }
    func registerPeer(_ cdhash: Data, reply: @escaping @Sendable (Int) -> Void) {
        guard let server else { reply(NextendoAgentStatus.unavailable.rawValue); return }
        do { try server.peers.register(cdhash); reply(NextendoAgentStatus.ok.rawValue) }
        catch { reply(NextendoAgentStatus.failed.rawValue) }
    }
    func accountDidChange(reply: @escaping @Sendable (UInt64) -> Void) {
        guard let server else { reply(0); return }
        Task { let generation = await server.account.accountDidChange(); server.push(generation); reply(generation) }
    }
    func status(reply: @escaping @Sendable (Int, Int, Int) -> Void) {
        guard let server else { reply(NextendoAgent.protocolVersion, 0, 0); return }
        reply(NextendoAgent.protocolVersion, server.peers.count, server.connectedPorts)
    }
}

// MARK: Studio's client

/// Studio's side of the administrator service. Every call is bounded and returns
/// nil when the agent is not registered, not running or refuses Studio.
public struct NextendoAgentAdminClient: Sendable {
    let makeConnection: @Sendable () -> NSXPCConnection
    let timeout: Duration
    public init(timeout: Duration = .seconds(3)) {
        self.init(timeout: timeout) {
            let connection = NSXPCConnection(machServiceName: NextendoAgent.adminService)
            // Talk only to the agent shipped inside this same app.
            let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NXPortStudioAgent")
            if let cdhash = try? NextendoAgentCode.cdhash(of: agent), let requirement = NextendoAgentCode.requirement(for: [cdhash]) {
                connection.setCodeSigningRequirement(requirement)
            }
            return connection
        }
    }
    init(timeout: Duration, makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.timeout = timeout; self.makeConnection = makeConnection
    }

    public func registerPeer(app: URL) async -> NextendoAgentStatus? {
        guard let cdhash = try? NextendoAgentCode.cdhash(of: app) else { return .refused }
        return await call { proxy, done in proxy.registerPeer(cdhash) { done(NextendoAgentStatus(wire: $0)) } }
    }
    public func accountDidChange() async -> UInt64? {
        await call { proxy, done in proxy.accountDidChange { done($0) } }
    }
    public func status() async -> (version: Int, peers: Int, ports: Int)? {
        await call { proxy, done in proxy.status { done(($0, $1, $2)) } }
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (NextendoAgentAdminService, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
        let connection = makeConnection()
        connection.remoteObjectInterface = NextendoAgentInterfaces.admin()
        let once = NextendoAgentOnce<T>()
        defer { connection.invalidate() }
        connection.resume()
        let box = NextendoAgentConnectionBox(connection)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.arm(continuation)
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { _ in once.finish(nil) }
            guard let service = proxy as? NextendoAgentAdminService else { once.finish(nil); return }
            body(service) { once.finish($0) }
            let deadline = timeout
            Task { try? await Task.sleep(for: deadline); once.finish(nil) }
        }
    }
}

/// Resumes a continuation exactly once: reply, error handler or timeout, whichever comes first.
final class NextendoAgentOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<T?, Never>?
    func arm(_ continuation: CheckedContinuation<T?, Never>) { lock.withLock { self.continuation = continuation } }
    func finish(_ value: T?) {
        let pending: CheckedContinuation<T?, Never>? = lock.withLock { let c = continuation; continuation = nil; return c }
        pending?.resume(returning: value)
    }
}

struct NextendoAgentConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
