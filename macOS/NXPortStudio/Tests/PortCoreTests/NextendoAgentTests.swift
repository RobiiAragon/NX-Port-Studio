import Foundation
import XCTest
@testable import PortCore

private final class AgentStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var session: NextendoSession?
    init(_ session: NextendoSession?) { self.session = session }
    func load() throws -> NextendoSession? { lock.withLock { session } }
    func save(_ session: NextendoSession) throws { lock.withLock { self.session = session } }
    func remove() throws { lock.withLock { session = nil } }
}
private struct FailingHTTP: NextendoHTTPClient {
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse { throw NextendoError.requestFailed }
}
/// Answers by path and records every request; nothing leaves the process.
private final class RecordingHTTP: NextendoHTTPClient, @unchecked Sendable {
    private let lock = NSLock(); private var seen: [URLRequest] = []
    private let answer: @Sendable (URLRequest) throws -> NextendoHTTPResponse
    init(_ answer: @escaping @Sendable (URLRequest) throws -> NextendoHTTPResponse) { self.answer = answer }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse { lock.withLock { seen.append(request) }; return try answer(request) }
    var requests: [URLRequest] { lock.withLock { seen } }
    func posted(_ path: String) -> [String] {
        requests.filter { $0.url?.path == path && $0.httpMethod == "POST" }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }
}
private func json(_ object: Any, status: Int = 200) -> NextendoHTTPResponse {
    NextendoHTTPResponse(data: try! JSONSerialization.data(withJSONObject: object), statusCode: status)
}
private func provider(_ request: URLRequest) throws -> NextendoHTTPResponse {
    switch request.url?.path {
    case "/api/friends": return json(["friends": [["pid": 501, "name": "SyntheticFriend"]]])
    case "/api/me": return json(["nsa": "abcdef0000001234"])
    case "/api/presence": return json([:])
    default: throw NextendoError.requestFailed
    }
}

private let socialScopes = ["identity", "game.matchmaking", "friends", "presence"]
private final class Generations: @unchecked Sendable {
    private let lock = NSLock(); private var seen: [UInt64] = []
    func add(_ value: UInt64) { lock.withLock { seen.append(value) } }
    var values: [UInt64] { lock.withLock { seen } }
}
private struct Endpoint: @unchecked Sendable { let value: NSXPCListenerEndpoint }
private func adminClient(_ listener: NSXPCListener, timeout: Duration) -> NextendoAgentAdminClient {
    let endpoint = Endpoint(value: listener.endpoint)
    return NextendoAgentAdminClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint.value) }
}
private final class Listener: NSObject, NextendoAgentListener, @unchecked Sendable {
    private let lock = NSLock(); private var seen: [UInt64] = []
    let changed = XCTestExpectation(description: "account change pushed")
    func accountChanged(_ generation: UInt64) { lock.withLock { seen.append(generation) }; changed.fulfill() }
    var generations: [UInt64] { lock.withLock { seen } }
}

final class NextendoAgentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // NEX claims carry whole seconds
    private func proof(_ expiry: Date, pid: UInt64 = 42) -> String {
        "nx2." + Data("\(pid).synthetic.\(Int64(expiry.timeIntervalSince1970))".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
    }
    private func nex(expired: Bool = false, renewal: Bool = true, scopes: [String] = socialScopes, access: TimeInterval = 3500) -> NextendoSession {
        let expiry = now.addingTimeInterval(expired ? -10 : 86_000)
        let session = NextendoSession(tokenKind: .nex, token: proof(expiry), identity: .init(pid: 42, username: "synthetic"),
                                      scopes: [], createdAt: now.addingTimeInterval(-100), expiresAt: expiry)
        return session.withRenewal(renewal ? .init(clientID: "nxnative-own-test-client", accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh-secret", expiresAt: now.addingTimeInterval(access), scopes: scopes) : nil)
    }
    // MARK: Record

    func testPortRecordDropsTheRenewalGrant() throws {
        let record = try nex().encodedForPort()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        XCTAssertNil(json["renewal"])
        XCTAssertFalse(String(decoding: record, as: UTF8.self).contains("synthetic-refresh-secret"))
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["token_kind"] as? String, "nex")
        XCTAssertEqual(try NextendoSession.decodeForPort(record, now: now).identity?.pid, 42)
    }

    func testPortRecordRejectsRenewalOAuthAndExpiry() throws {
        XCTAssertThrowsError(try NextendoSession.decodeForPort(nex().encodedForStorage(), now: now))
        XCTAssertThrowsError(try NextendoSession.decodeForPort(nex(expired: true, renewal: false).encodedForStorage(), now: now))
        let oauth = NextendoSession(tokenKind: .oauth, token: "synthetic-access", identity: nil, scopes: ["identity"], createdAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertThrowsError(try NextendoSession.decodeForPort(oauth.encodedForStorage(), now: now))
        XCTAssertThrowsError(try NextendoSession.decodeForPort(Data(count: NextendoAgent.credentialLimit + 1), now: now))
    }

    // MARK: Code identity

    func testRequirementMatchesExactlyTheRegisteredHashes() {
        let a = Data(repeating: 0xab, count: 20), b = Data((0..<20).map { UInt8($0) })
        XCTAssertNil(NextendoAgentCode.requirement(for: []))
        XCTAssertNil(NextendoAgentCode.requirement(for: [Data(count: 19), Data(count: 32)]))
        XCTAssertEqual(NextendoAgentCode.requirement(for: [a]), "cdhash H\"" + String(repeating: "ab", count: 20) + "\"")
        XCTAssertEqual(NextendoAgentCode.requirement(for: [a, Data(count: 3), b]),
                       "cdhash H\"\(NextendoAgentCode.hex(a))\" or cdhash H\"000102030405060708090a0b0c0d0e0f10111213\"")
        XCTAssertEqual(NextendoAgentCode.data(hex: NextendoAgentCode.hex(b)), b)
        XCTAssertNil(NextendoAgentCode.data(hex: "zz" + String(repeating: "0", count: 38)))
        XCTAssertNil(NextendoAgentCode.data(hex: "00"))
    }

    func testPeersDeduplicateKeepTheNewestAndPersist() throws {
        let store = NextendoAgentMemoryPeerStore()
        let peers = NextendoAgentPeers(store: store)
        XCTAssertNil(peers.requirement)
        XCTAssertThrowsError(try peers.register(Data(count: 5)))
        for i in 0..<(NextendoAgent.peerLimit + 3) { try peers.register(Data(repeating: UInt8(i % 256), count: 19) + Data([UInt8(i / 256)])) }
        try peers.register(Data(repeating: 5, count: 19) + Data([0]))   // again: moves to the end
        XCTAssertEqual(peers.count, NextendoAgent.peerLimit)
        let saved = try store.load()
        XCTAssertEqual(saved.last, Data(repeating: 5, count: 19) + Data([0]))
        XCTAssertFalse(saved.contains(Data(repeating: 0, count: 20)))   // the oldest fell off
        XCTAssertEqual(NextendoAgentPeers(store: store).count, NextendoAgent.peerLimit)
    }

    // MARK: Account

    func testCredentialStatusFollowsTheStore() async throws {
        let store = AgentStore(nex())
        let account = NextendoAgentAccount(store: store, http: FailingHTTP(), now: { [now] in now })
        var result = await account.credential(renew: false)
        XCTAssertEqual(result.status, .ok)
        XCTAssertNoThrow(try NextendoSession.decodeForPort(XCTUnwrap(result.record), now: now))
        // A failed renewal keeps the stored record, as a port's own boot does.
        result = await account.credential(renew: true)
        XCTAssertEqual(result.status, .ok)
        try store.save(nex(expired: true))
        result = await account.credential(renew: false)
        XCTAssertEqual(result.status, .unavailable); XCTAssertNil(result.record)
        try store.remove()
        result = await account.credential(renew: false)
        XCTAssertEqual(result.status, .signedOut); XCTAssertNil(result.record)
        let before = result.generation
        let after = await account.accountDidChange()
        XCTAssertEqual(after, before + 1)
    }

    // MARK: Account API

    func testSocialUsesTheAgentGrantAndSharesOneFriendsSnapshot() async throws {
        let http = RecordingHTTP { try provider($0) }
        let account = NextendoAgentAccount(store: AgentStore(nex()), http: http, now: { [now] in now })
        let first = await account.social("friends", body: nil, port: 1)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(first.http, 200)
        XCTAssertTrue(String(decoding: try XCTUnwrap(first.body), as: UTF8.self).contains("SyntheticFriend"))
        let second = await account.social("friends", body: Data(), port: 2)   // another port, same snapshot
        XCTAssertEqual(second.body, first.body)
        XCTAssertEqual(http.requests.count, 1)
        let friends = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(friends.url?.absoluteString, "https://nextendo.network/api/friends?images=0")
        XCTAssertEqual(friends.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
        XCTAssertEqual(friends.httpMethod, "GET")
        _ = await account.social("me", body: nil, port: 1); _ = await account.social("me", body: nil, port: 2)
        XCTAssertEqual(http.requests.count, 2)   // the identity does not change within a generation
        let presence = await account.social("presence", body: Data(#"{"status":2}"#.utf8), port: 1)
        XCTAssertEqual(presence.status, .ok); XCTAssertEqual(http.posted("/api/presence"), [#"{"status":2}"#])
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        for (resource, body) in [("../friends", nil), ("oauth/token", nil), ("friends", Data("{}".utf8)), ("me", Data("{}".utf8)),
                                 ("presence", nil), ("presence", Data("[1]".utf8)), ("presence", Data(count: NextendoAgent.presenceLimit + 1))] as [(String, Data?)] {
            let refused = await account.social(resource, body: body, port: 1)
            XCTAssertEqual(refused.status, .refused, resource); XCTAssertNil(refused.body)
        }
        XCTAssertEqual(http.requests.count, 3)
    }

    func testSocialReportsTheAccountStateAndHTTPFailures() async throws {
        let http = RecordingHTTP { request in
            if request.url?.path == "/api/me" { throw NextendoError.requestFailed }
            return json(["error": "forbidden"], status: 403)
        }
        let store = AgentStore(nil)
        let account = NextendoAgentAccount(store: store, http: http, now: { [now] in now })
        var reply = await account.social("friends", body: nil, port: 1)
        XCTAssertEqual(reply.status, .signedOut); XCTAssertEqual(reply.http, 0)
        try store.save(nex(renewal: false))   // a record with no grant: nothing to sign the request with
        reply = await account.social("friends", body: nil, port: 1); XCTAssertEqual(reply.status, .unavailable)
        try store.save(nex(scopes: ["identity", "game.matchmaking"]))
        reply = await account.social("presence", body: Data("{}".utf8), port: 1); XCTAssertEqual(reply.status, .unavailable)
        try store.save(nex(expired: true))
        reply = await account.social("friends", body: nil, port: 1); XCTAssertEqual(reply.status, .unavailable)
        XCTAssertTrue(http.requests.isEmpty)
        try store.save(nex())
        reply = await account.social("friends", body: nil, port: 1)
        XCTAssertEqual(reply.status, .ok); XCTAssertEqual(reply.http, 403); XCTAssertNil(reply.body)
        reply = await account.social("friends", body: nil, port: 1)
        XCTAssertEqual(http.requests.count, 2)   // a failed answer is not cached
        reply = await account.social("me", body: nil, port: 1); XCTAssertEqual(reply.status, .failed)
    }

    func testPresenceShowsTheNewestDeclaration() async throws {
        let http = RecordingHTTP { try provider($0) }
        let account = NextendoAgentAccount(store: AgentStore(nex()), http: http, now: { [now] in now })
        let a = Data(#"{"app_id":"a"}"#.utf8), b = Data(#"{"app_id":"b"}"#.utf8), a2 = Data(#"{"app_id":"a","status":1}"#.utf8)
        _ = await account.social("presence", body: a, port: 1)
        _ = await account.social("presence", body: b, port: 2)    // a game started later
        _ = await account.social("presence", body: a, port: 1)    // port 1's refresh keeps b shown
        await account.portDisconnected(1)                         // not shown: nothing to send
        _ = await account.social("presence", body: a2, port: 3)   // a new declaration wins
        _ = await account.social("presence", body: b, port: 2)
        await account.portDisconnected(3)                         // shown: the next newest takes over
        await account.portDisconnected(9)
        let bodies = http.posted("/api/presence").map { String($0.dropFirst(11).prefix(1)) }
        XCTAssertEqual(bodies, ["a", "b", "b", "a", "a", "b"])
    }

    func testAccountChangeClearsSnapshotsAndNotifies() async throws {
        let http = RecordingHTTP { try provider($0) }
        let account = NextendoAgentAccount(store: AgentStore(nex()), http: http, now: { [now] in now })
        let pushed = Generations(); account.notifier.set { pushed.add($0) }
        _ = await account.social("friends", body: nil, port: 1)
        _ = await account.social("presence", body: Data(#"{"app_id":"b"}"#.utf8), port: 2)
        let generation = await account.accountDidChange()
        XCTAssertEqual(generation, 2); XCTAssertEqual(pushed.values, [2])
        _ = await account.social("friends", body: nil, port: 1)
        _ = await account.social("presence", body: Data(#"{"app_id":"a"}"#.utf8), port: 1)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/friends" }.count, 2)
        XCTAssertEqual(http.posted("/api/presence").last, #"{"app_id":"a"}"#)   // the old account's presence is gone
    }

    func testExpiringGrantRenewsOnceAndPushesTheNewRecord() async throws {
        let renewedExpiry = now.addingTimeInterval(86_500)
        let renewedProof = proof(renewedExpiry)
        let http = RecordingHTTP { request in
            switch request.url?.path {
            case "/api/oauth/token":
                return json(["access_token": "synthetic-access-2", "token_type": "Bearer", "refresh_token": "synthetic-refresh-2",
                             "expires_in": 3600, "scope": socialScopes.joined(separator: " ")])
            case "/api/oauth/userinfo": return json(["pid": 42, "username": "synthetic"])
            case "/api/nex-token": return json(["nex_token": renewedProof, "account": ["pid": 42, "username": "synthetic"]])
            default: return try provider(request)
            }
        }
        let store = AgentStore(nex(access: 30))   // the access token is about to expire
        let account = NextendoAgentAccount(store: store, http: http, now: { [now] in now })
        let pushed = Generations(); account.notifier.set { pushed.add($0) }
        let reply = await account.social("friends", body: nil, port: 1)
        XCTAssertEqual(reply.status, .ok)
        XCTAssertEqual(http.requests.map { $0.url?.path ?? "" }, ["/api/oauth/token", "/api/oauth/userinfo", "/api/nex-token", "/api/friends"])
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-2")
        XCTAssertEqual(try store.load()?.token, renewedProof)
        XCTAssertEqual(pushed.values, [2])   // running ports fetch the new NEX record
        let credential = await account.credential(renew: false)
        XCTAssertEqual(credential.generation, 2)
        XCTAssertEqual(try NextendoSession.decodeForPort(XCTUnwrap(credential.record), now: now).token, renewedProof)
    }

    // MARK: XPC, with the real code-signing check

    private func server(peers: [Data], admin: [Data], store: AgentStore) -> (NextendoAgentServer, NSXPCListener, NSXPCListener) {
        let port = NSXPCListener.anonymous(), adminListener = NSXPCListener.anonymous()
        let http = RecordingHTTP { try provider($0) }
        let server = NextendoAgentServer(portListener: port, adminListener: adminListener,
            account: NextendoAgentAccount(store: store, http: http, now: { [now] in now }),
            peerStore: NextendoAgentMemoryPeerStore(peers), adminRequirement: NextendoAgentCode.requirement(for: admin))
        server.resume()
        return (server, port, adminListener)
    }
    private func portConnection(_ listener: NSXPCListener, exported: Listener? = nil) -> NSXPCConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NextendoAgentInterfaces.port()
        if let exported { connection.exportedInterface = NextendoAgentInterfaces.listener(); connection.exportedObject = exported }
        connection.resume(); return connection
    }

    func testRegisteredPortGetsItsCredentialAndAccountChanges() async throws {
        let me = try NextendoAgentCode.ownCDHash()
        let (server, port, admin) = server(peers: [me], admin: [me], store: AgentStore(nex()))
        let listener = Listener()
        let connection = portConnection(port, exported: listener); defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { XCTFail("port refused: \($0)") } as? NextendoAgentPortService)

        let hello = expectation(description: "hello")
        proxy.hello(NextendoAgent.protocolVersion, titleID: "0100000000010000", gameVersion: "1.0.0") { status, version in
            XCTAssertEqual(NextendoAgentStatus(wire: status), .ok); XCTAssertEqual(version, NextendoAgent.protocolVersion); hello.fulfill()
        }
        let mismatch = expectation(description: "version mismatch")
        proxy.hello(NextendoAgent.protocolVersion + 1, titleID: "0100000000010000", gameVersion: "1.0.0") { status, _ in
            XCTAssertEqual(NextendoAgentStatus(wire: status), .versionMismatch); mismatch.fulfill()
        }
        let credential = expectation(description: "credential")
        let now = self.now
        proxy.gameCredential(renew: false) { status, record, generation in
            XCTAssertEqual(NextendoAgentStatus(wire: status), .ok); XCTAssertEqual(generation, 1)
            XCTAssertNotNil(record.flatMap { try? NextendoSession.decodeForPort($0, now: now) }); credential.fulfill()
        }
        let social = expectation(description: "social")
        proxy.social("friends", body: nil) { status, http, body in
            XCTAssertEqual(NextendoAgentStatus(wire: status), .ok); XCTAssertEqual(http, 200)
            XCTAssertTrue(String(decoding: body ?? Data(), as: UTF8.self).contains("SyntheticFriend")); social.fulfill()
        }
        await fulfillment(of: [hello, mismatch, credential, social], timeout: 5)

        let client = adminClient(admin, timeout: .seconds(5))
        let generation = await client.accountDidChange()
        XCTAssertEqual(generation, 2)
        await fulfillment(of: [listener.changed], timeout: 5)
        XCTAssertEqual(listener.generations, [2])
        let status = await client.status()
        XCTAssertEqual(status?.peers, 1); XCTAssertEqual(status?.ports, 1)
        let registered = await client.registerPeer(app: try XCTUnwrap(Bundle.main.executableURL))
        XCTAssertEqual(registered, .ok)
        XCTAssertEqual(server.peers.count, 1)   // the same cdhash, not a second entry
    }

    func testUnregisteredPortAndForeignAdministratorAreRefused() async throws {
        let other = Data(repeating: 0x5a, count: 20)
        let (_, port, admin) = server(peers: [other], admin: [other], store: AgentStore(nex()))
        let connection = portConnection(port); defer { connection.invalidate() }
        let refused = expectation(description: "refused")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { _ in refused.fulfill() } as? NextendoAgentPortService)
        proxy.gameCredential(renew: false) { _, record, _ in XCTAssertNil(record, "a refused port must not get a record") }
        await fulfillment(of: [refused], timeout: 5)

        let client = adminClient(admin, timeout: .seconds(2))
        let generation = await client.accountDidChange()
        XCTAssertNil(generation)
    }

    func testNoRegisteredPortsAndNoAdministratorRefuseEverything() async throws {
        let (_, port, admin) = server(peers: [], admin: [], store: AgentStore(nex()))
        let connection = portConnection(port); defer { connection.invalidate() }
        let refused = expectation(description: "refused")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { _ in refused.fulfill() } as? NextendoAgentPortService)
        proxy.hello(NextendoAgent.protocolVersion, titleID: "", gameVersion: "") { _, _ in XCTFail("accepted without registration") }
        await fulfillment(of: [refused], timeout: 5)
        let status = await adminClient(admin, timeout: .seconds(2)).status()
        XCTAssertNil(status)
    }

    func testAdminClientTimesOutWhenTheAgentNeverReplies() async {
        // A listener that accepts nothing and never answers stands in for a hung agent.
        let silent = NSXPCListener.anonymous()
        final class Hold: NSObject, NSXPCListenerDelegate { func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool { c.resume(); return true } }
        let hold = Hold(); silent.delegate = hold; silent.resume()
        let started = ContinuousClock.now
        let status = await adminClient(silent, timeout: .milliseconds(300)).status()
        XCTAssertNil(status)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        _ = hold
    }
}
