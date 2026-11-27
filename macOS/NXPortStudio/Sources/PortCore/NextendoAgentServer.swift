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
        // Only the code directory is the identity, and XPC checks it again on every
        // connection; hashing every sealed resource would read a whole port (many GB).
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess
        else { throw NextendoError.authorizationUnavailable }
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

/// Delivers generation changes to the server, which pushes them to every port.
final class NextendoAgentNotifier: @unchecked Sendable {
    private let lock = NSLock(); private var handler: (@Sendable (UInt64) -> Void)?
    func set(_ handler: @escaping @Sendable (UInt64) -> Void) { lock.withLock { self.handler = handler } }
    func send(_ generation: UInt64) { lock.withLock { handler }?(generation) }
}

/// Owns renewal and the account API for every port that connects. Studio still
/// signs in and out itself and reports each change. Every change of the stored
/// record (Studio's, or a renewal here) bumps the generation pushed to ports.
public actor NextendoAgentAccount {
    public typealias Reply = (status: NextendoAgentStatus, http: Int, body: Data?)
    private let service: NextendoAccountService
    private let store: any NextendoCredentialStore
    private let http: any NextendoHTTPClient
    private let now: @Sendable () -> Date
    nonisolated let notifier = NextendoAgentNotifier()
    public private(set) var generation: UInt64 = 1
    /// One friends snapshot for every port, at most this old.
    static let friendsAge: TimeInterval = 15
    private var friends: (body: Data, at: Date, generation: UInt64)?
    private var friendsFetch: Task<Reply, Never>?
    private var me: (body: Data, generation: UInt64)?
    /// The provider keeps one presence per account. Each port's latest body, and when
    /// it last changed: the most recent change is what Nextendo shows.
    private var presence: [UInt64: (body: Data, declared: UInt64)] = [:]
    private var declarations: UInt64 = 0

    public init(store: any NextendoCredentialStore = NextendoKeychainStore(), http: any NextendoHTTPClient = NextendoURLSessionClient(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.http = http; self.now = now
        service = NextendoAccountService(store: store, http: http, now: now)
    }

    public func credential(renew: Bool) async -> (status: NextendoAgentStatus, record: Data?, generation: UInt64) {
        if renew {
            // Same policy as a port's own boot (dm/mac/GameAccount.swift): a failed
            // renewal keeps the stored record, which the host validates again.
            guard await prepare(force: true) else { return (.failed, nil, generation) }
        }
        let session: NextendoSession?
        do { session = try store.load() } catch { return (.unavailable, nil, generation) }
        guard let session else { return (.signedOut, nil, generation) }
        guard session.tokenKind == .nex, !session.summary(at: now()).isExpired,
              let record = try? session.encodedForPort(), record.count <= NextendoAgent.credentialLimit else { return (.unavailable, nil, generation) }
        return (.ok, record, generation)
    }

    /// Studio changed the stored account: the old account's caches and presence go.
    public func accountDidChange() -> UInt64 { changed(account: true); return generation }

    private func changed(account: Bool) {
        generation &+= 1; friends = nil; me = nil
        if account { presence = [:] }
        notifier.send(generation)
    }

    /// Runs the shared preparation; false only when cancelled. A record it replaced
    /// reaches the ports, so a long session never outlives its NEX proof.
    private func prepare(force: Bool) async -> Bool {
        let before = try? store.load()?.token
        do { _ = try await service.prepareGameAccount(forceGameRefresh: force) }
        catch is CancellationError { return false }
        catch { agentLog.error("game account preparation failed; the stored account is used") }
        if (try? store.load()?.token) != before { changed(account: false) }
        return true
    }

    // MARK: Account API

    public func social(_ resource: String, body: Data?, port: UInt64) async -> Reply {
        let body = body?.isEmpty == true ? nil : body
        switch resource {
        case "friends" where body == nil: return await friendsSnapshot()
        case "me" where body == nil:
            if let me, me.generation == generation { return (.ok, 200, me.body) }
            let started = generation, reply = await send("me", body: nil)
            if reply.status == .ok, let data = reply.body, started == generation { me = (data, started) }
            return reply
        case "presence":
            guard let body, body.count <= NextendoAgent.presenceLimit,
                  (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else { return (.refused, 0, nil) }
            if presence[port]?.body != body { declarations &+= 1; presence[port] = (body, declarations) }
            // A port's unchanged refresh keeps the newest declaration alive instead of replacing it.
            return await send("presence", body: current() ?? body)
        default: return (.refused, 0, nil)
        }
    }

    /// A port quit: if it held the shown presence, the next newest port's takes over.
    public func portDisconnected(_ port: UInt64) async {
        guard let gone = presence.removeValue(forKey: port), let next = presence.values.max(by: { $0.declared < $1.declared }),
              next.declared < gone.declared else { return }
        _ = await send("presence", body: next.body)
    }

    // MARK: Hub (Studio and the agent itself)

    /// Accepts or declines an incoming friend request, then drops the shared snapshot.
    public func answerFriendRequest(_ pid: UInt64, accept: Bool) async -> Reply {
        guard pid > 0, let body = try? JSONSerialization.data(withJSONObject: ["pid": pid]) else { return (.refused, 0, nil) }
        let reply = await send(path: accept ? "friends/accept" : "friends/decline", scope: "friends", body: body)
        if reply.status == .ok, (200..<300).contains(reply.http) { friends = nil }
        return reply
    }

    /// `GET /api/session-status` with the game token, as the developer guide documents:
    /// `revoked` is true when this device's game session was closed on the website.
    public func sessionRevoked() async -> (status: NextendoAgentStatus, revoked: Bool?) {
        let session: NextendoSession?
        do { session = try store.load() } catch { return (.unavailable, nil) }
        guard let session else { return (.signedOut, nil) }
        guard session.tokenKind == .nex, !session.summary(at: now()).isExpired else { return (.unavailable, nil) }
        let reply = await request(path: "session-status", bearer: session.token, body: nil)
        guard reply.status == .ok else { return (reply.status, nil) }
        guard (200..<300).contains(reply.http), let body = reply.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let revoked = object["revoked"] as? NSNumber, CFGetTypeID(revoked) == CFBooleanGetTypeID() else { return (.failed, nil) }
        return (.ok, revoked.boolValue)
    }

    /// The website closed this Mac's session: sign out here as Studio would, and tell the ports.
    public func signOutRevoked() async {
        do { try await service.signOut() } catch { agentLog.error("revoked account could not be removed") }
        changed(account: true)
    }

    private func current() -> Data? { presence.values.max(by: { $0.declared < $1.declared })?.body }

    private func friendsSnapshot() async -> Reply {
        if let friends, friends.generation == generation, now().timeIntervalSince(friends.at) < Self.friendsAge { return (.ok, 200, friends.body) }
        if let friendsFetch { return await friendsFetch.value }
        let started = generation
        let task = Task { await self.send("friends", body: nil) }
        friendsFetch = task
        let reply = await task.value
        friendsFetch = nil
        if reply.status == .ok, let data = reply.body, started == generation { friends = (data, now(), started) }
        return reply
    }

    /// The OAuth access for a scope, renewed first when it is about to expire.
    private func access(_ scope: String) async -> (status: NextendoAgentStatus, token: String?) {
        for attempt in 0..<2 {
            let session: NextendoSession?
            do { session = try store.load() } catch { return (.unavailable, nil) }
            guard let session else { return (.signedOut, nil) }
            guard session.tokenKind == .nex, !session.summary(at: now()).isExpired,
                  let grant = session.renewal, grant.scopes.contains(scope) else {
                agentLog.error("no OAuth grant for scope \(scope, privacy: .public); sign in again in Studio")
                return (.unavailable, nil)
            }
            if grant.expiresAt > now().addingTimeInterval(60) { return (.ok, grant.accessToken) }
            if attempt == 0 { guard await prepare(force: false) else { return (.failed, nil) } }
        }
        return (.unavailable, nil)
    }

    private func send(_ resource: String, body: Data?) async -> Reply {
        guard let scope = NextendoAgent.socialScopes[resource] else { return (.refused, 0, nil) }
        // Each friend otherwise carries its base64 profile image; no port reads one.
        return await send(path: resource == "friends" ? "friends?images=0" : resource, scope: scope, body: body)
    }

    private func send(path: String, scope: String, body: Data?) async -> Reply {
        let authorization = await access(scope)
        guard let token = authorization.token else { return (authorization.status, 0, nil) }
        return await request(path: path, bearer: token, body: body)
    }

    private func request(path: String, bearer token: String, body: Data?) async -> Reply {
        var request = URLRequest(url: URL(string: "https://nextendo.network/api/" + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.timeoutInterval = 12
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("NX-Port-Studio", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: NextendoHTTPResponse
        do { response = try await http.send(request) } catch {
            agentLog.error("provider request failed: \(String(describing: error), privacy: .public)")
            return (.failed, 0, nil)
        }
        guard response.data.count <= NextendoAgent.responseLimit else {
            agentLog.error("provider answer of \(response.data.count, privacy: .public) bytes is over the agent's limit")
            return (.failed, response.statusCode, nil)
        }
        if !(200..<300).contains(response.statusCode) { agentLog.error("provider answered HTTP \(response.statusCode, privacy: .public)") }
        return (.ok, response.statusCode, (200..<300).contains(response.statusCode) ? response.data : nil)
    }
}

// MARK: XPC

public final class NextendoAgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let portListener: NSXPCListener, adminListener: NSXPCListener
    let account: NextendoAgentAccount
    let peers: NextendoAgentPeers
    /// nil in a server without notifications (tests that do not exercise the hub).
    private(set) var hub: NextendoAgentHub?
    private var hubTask: Task<Void, Never>?
    private let adminRequirement: String?
    private let lock = NSLock()
    private var ports: [UInt64: NSXPCConnection] = [:]
    private var nextPort: UInt64 = 0

    /// `adminRequirement` nil refuses every administrator; a port is accepted only
    /// when its code matches a registered cdhash.
    public init(portListener: NSXPCListener, adminListener: NSXPCListener, account: NextendoAgentAccount,
                peerStore: any NextendoAgentPeerStore, adminRequirement: String?,
                notifier: (any NextendoHubNotifying)? = nil, settings: any NextendoHubSettings = NextendoHubMemorySettings(),
                games: @escaping @Sendable () -> [String: String] = { NextendoInstalledGames.names() }) {
        self.portListener = portListener; self.adminListener = adminListener; self.account = account
        peers = NextendoAgentPeers(store: peerStore); self.adminRequirement = adminRequirement
        super.init()
        portListener.delegate = self; adminListener.delegate = self
        account.notifier.set { [weak self] in self?.push($0) }
        if let notifier {
            hub = NextendoAgentHub(account: account, notifier: notifier, settings: settings,
                                   connectedPorts: { [weak self] in self?.connectedPorts ?? 0 }, games: games)
        }
    }

    /// The launchd agent inside NX Port Studio.app: its administrator is exactly that app.
    public static func launchd(notifier: any NextendoHubNotifying) -> NextendoAgentServer {
        var requirement: String?
        if let app = studioBundle(containing: Bundle.main.bundleURL), let studio = try? NextendoAgentCode.cdhash(of: app) {
            requirement = NextendoAgentCode.requirement(for: [studio])
        } else { agentLog.error("not inside a signed NX Port Studio.app; administration is refused") }
        return NextendoAgentServer(portListener: NSXPCListener(machServiceName: NextendoAgent.portService),
                                   adminListener: NSXPCListener(machServiceName: NextendoAgent.adminService),
                                   account: NextendoAgentAccount(), peerStore: NextendoAgentKeychainPeerStore(), adminRequirement: requirement,
                                   notifier: notifier, settings: NextendoHubDefaults())
    }

    /// Studio's bundle for an agent app at `NextendoAgent.bundlePath` inside it.
    static func studioBundle(containing agent: URL) -> URL? {
        let parts = NextendoAgent.bundlePath.split(separator: "/").count
        var studio = agent.standardizedFileURL
        for _ in 0..<parts { studio.deleteLastPathComponent() }
        guard agent.pathExtension == "app", studio.pathExtension == "app",
              studio.appendingPathComponent(NextendoAgent.bundlePath).standardizedFileURL.path == agent.standardizedFileURL.path else { return nil }
        return studio
    }

    public func resume() {
        portListener.resume(); adminListener.resume()
        if let hub, hubTask == nil { hubTask = Task { await hub.run() } }
    }
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
        let key: UInt64 = lock.withLock { nextPort &+= 1; return nextPort }
        connection.exportedInterface = NextendoAgentInterfaces.port()
        connection.exportedObject = NextendoAgentPortSession(server: self, port: key)
        connection.remoteObjectInterface = NextendoAgentInterfaces.listener()
        let account = self.account
        connection.invalidationHandler = { [weak self] in
            self?.lock.withLock { _ = self?.ports.removeValue(forKey: key) }
            Task { await account.portDisconnected(key) }
        }
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
    private let port: UInt64
    init(server: NextendoAgentServer, port: UInt64) { self.server = server; self.port = port }
    func hello(_ version: Int, titleID: String, gameVersion: String, reply: @escaping @Sendable (Int, Int) -> Void) {
        let status: NextendoAgentStatus = version == NextendoAgent.protocolVersion ? .ok : .versionMismatch
        reply(status.rawValue, NextendoAgent.protocolVersion)
    }
    func gameCredential(renew: Bool, reply: @escaping @Sendable (Int, Data?, UInt64) -> Void) {
        guard let account = server?.account else { reply(NextendoAgentStatus.unavailable.rawValue, nil, 0); return }
        Task { let result = await account.credential(renew: renew); reply(result.status.rawValue, result.record, result.generation) }
    }
    func social(_ resource: String, body: Data?, reply: @escaping @Sendable (Int, Int, Data?) -> Void) {
        guard let account = server?.account else { reply(NextendoAgentStatus.unavailable.rawValue, 0, nil); return }
        let port = self.port
        Task { let result = await account.social(resource, body: body, port: port); reply(result.status.rawValue, result.http, result.body) }
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
        Task { reply(await server.account.accountDidChange()) }   // the notifier pushes it
    }
    func status(reply: @escaping @Sendable (Int, Int, Int) -> Void) {
        guard let server else { reply(NextendoAgent.protocolVersion, 0, 0); return }
        reply(NextendoAgent.protocolVersion, server.peers.count, server.connectedPorts)
    }
    func friends(reply: @escaping @Sendable (Int, Data?) -> Void) {
        guard let account = server?.account else { reply(NextendoAgentStatus.unavailable.rawValue, nil); return }
        Task {
            let result = await account.social("friends", body: nil, port: 0)
            let ok = result.status == .ok && (200..<300).contains(result.http)
            reply((ok ? NextendoAgentStatus.ok : result.status == .ok ? .failed : result.status).rawValue, ok ? result.body : nil)
        }
    }
    func answerFriendRequest(_ pid: UInt64, accept: Bool, reply: @escaping @Sendable (Int, Int) -> Void) {
        guard let account = server?.account else { reply(NextendoAgentStatus.unavailable.rawValue, 0); return }
        Task { let result = await account.answerFriendRequest(pid, accept: accept); reply(result.status.rawValue, result.http) }
    }
    func setNotifications(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        guard let hub = server?.hub else { reply(false); return }
        Task { reply(await hub.setNotifications(enabled)) }
    }
    func notifications(reply: @escaping @Sendable (Bool) -> Void) {
        guard let hub = server?.hub else { reply(false); return }
        Task { reply(await hub.notificationsEnabled) }
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
            let agent = Bundle.main.bundleURL.appendingPathComponent(NextendoAgent.bundlePath)
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
    public func friends() async -> (status: NextendoAgentStatus, view: NextendoFriendsView?)? {
        await call { proxy, done in
            proxy.friends { status, body in
                let view = body.flatMap(NextendoFriendsView.decode)
                done((view == nil && NextendoAgentStatus(wire: status) == .ok ? .failed : NextendoAgentStatus(wire: status), view))
            }
        }
    }
    public func answerFriendRequest(_ pid: UInt64, accept: Bool) async -> (status: NextendoAgentStatus, http: Int)? {
        await call { proxy, done in proxy.answerFriendRequest(pid, accept: accept) { done((NextendoAgentStatus(wire: $0), $1)) } }
    }
    public func setNotifications(_ enabled: Bool) async -> Bool? {
        // macOS may show its permission prompt first: allow time for the answer.
        await call(timeout: .seconds(120)) { proxy, done in proxy.setNotifications(enabled) { done($0) } }
    }
    public func notifications() async -> Bool? {
        await call { proxy, done in proxy.notifications { done($0) } }
    }

    private func call<T: Sendable>(timeout: Duration? = nil, _ body: @escaping @Sendable (NextendoAgentAdminService, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
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
            let deadline = timeout ?? self.timeout
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
