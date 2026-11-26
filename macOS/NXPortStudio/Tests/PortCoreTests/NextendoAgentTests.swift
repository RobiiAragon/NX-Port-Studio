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
    private func nex(expired: Bool = false, renewal: Bool = true) -> NextendoSession {
        let expiry = now.addingTimeInterval(expired ? -10 : 86_000)
        let session = NextendoSession(tokenKind: .nex, token: proof(expiry), identity: .init(pid: 42, username: "synthetic"),
                                      scopes: [], createdAt: now.addingTimeInterval(-100), expiresAt: expiry)
        return session.withRenewal(renewal ? .init(clientID: "nxnative-own-test-client", accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh-secret", expiresAt: now.addingTimeInterval(3500), scopes: ["identity", "game.matchmaking"]) : nil)
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

    // MARK: XPC, with the real code-signing check

    private func server(peers: [Data], admin: [Data], store: AgentStore) -> (NextendoAgentServer, NSXPCListener, NSXPCListener) {
        let port = NSXPCListener.anonymous(), adminListener = NSXPCListener.anonymous()
        let server = NextendoAgentServer(portListener: port, adminListener: adminListener,
            account: NextendoAgentAccount(store: store, http: FailingHTTP(), now: { [now] in now }),
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
        await fulfillment(of: [hello, mismatch, credential], timeout: 5)

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
