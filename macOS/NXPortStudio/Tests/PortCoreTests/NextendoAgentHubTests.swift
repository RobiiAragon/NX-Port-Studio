import Foundation
import XCTest
@testable import PortCore

private final class HubStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var session: NextendoSession?
    init(_ session: NextendoSession?) { self.session = session }
    func load() throws -> NextendoSession? { lock.withLock { session } }
    func save(_ session: NextendoSession) throws { lock.withLock { self.session = session } }
    func remove() throws { lock.withLock { session = nil } }
}
/// A settable clock and provider: the friends body, the session-status answer and every request.
private final class Provider: NextendoHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var friendsBody: [String: Any] = ["friends": [], "requests": []]
    private var friendsStatus = 200
    private var revoked = false
    private var seen: [URLRequest] = []
    var time = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    func set(friends: [[String: Any]], requests: [[String: Any]] = [], status: Int = 200) {
        lock.withLock { friendsBody = ["friends": friends, "requests": requests, "sent": []]; friendsStatus = status }
    }
    func set(revoked value: Bool) { lock.withLock { revoked = value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time = time.addingTimeInterval(seconds) } }
    var now: Date { lock.withLock { time } }
    var requests: [URLRequest] { lock.withLock { seen } }
    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        lock.withLock { seen.append(request) }
        let answer: (Any, Int) = lock.withLock {
            switch request.url?.path {
            case "/api/friends": return (friendsBody, friendsStatus)
            case "/api/session-status": return (["email_verified": true, "revoked": revoked], 200)
            case "/api/friends/accept", "/api/friends/decline": return (["ok": true], 200)
            default: return ([:], 404)
            }
        }
        return NextendoHTTPResponse(data: try JSONSerialization.data(withJSONObject: answer.0), statusCode: answer.1)
    }
}
private final class Notifications: NextendoHubNotifying, @unchecked Sendable {
    private let lock = NSLock(); private var seen: [NextendoHubEvent] = []
    let granted: Bool
    init(granted: Bool = true) { self.granted = granted }
    func authorize() async -> Bool { granted }
    func post(_ event: NextendoHubEvent) async { lock.withLock { seen.append(event) } }
    var events: [NextendoHubEvent] { lock.withLock { seen } }
}
private final class Ports: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func set(_ count: Int) { lock.withLock { value = count } }
    var count: Int { lock.withLock { value } }
}

final class NextendoAgentHubTests: XCTestCase {
    private func session(_ provider: Provider) -> NextendoSession {
        let now = provider.now, expiry = now.addingTimeInterval(86_000)
        let token = "nx2." + Data("42.synthetic.\(Int64(expiry.timeIntervalSince1970))".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        return NextendoSession(tokenKind: .nex, token: token, identity: .init(pid: 42, username: "synthetic"), scopes: [],
                               createdAt: now.addingTimeInterval(-100), expiresAt: expiry)
            .withRenewal(.init(clientID: "nxnative-own-test-client", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                               expiresAt: now.addingTimeInterval(80_000), scopes: ["identity", "game.matchmaking", "friends", "presence"]))
    }
    private func friend(_ pid: UInt64, _ name: String, status: Int = 0, title: String = "") -> [String: Any] {
        ["pid": pid, "name": name, "presence": ["status": status, "app_id": title, "app_field": ""]]
    }
    private func hub(_ provider: Provider, store: HubStore, notifications: Notifications = Notifications(), on: Bool = true,
                     ports: Ports = Ports()) -> (NextendoAgentHub, NextendoAgentAccount) {
        let account = NextendoAgentAccount(store: store, http: provider, now: { provider.now })
        let hub = NextendoAgentHub(account: account, notifier: notifications, settings: NextendoHubMemorySettings(notifications: on),
                                   connectedPorts: { ports.count }, games: { ["0100000000010000": "Synthetic Port"] })
        return (hub, account)
    }

    func testFriendsViewKeepsWhatStudioShows() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "friends": [["pid": 7, "name": "Seven", "presence": ["status": 2, "app_id": "0100000000010000"]],
                        ["pid": 8, "username": "eight", "presence": ["status": 9, "app_id": "not-a-title"]],
                        ["pid": true, "name": "bool pid"], ["name": "no pid"], "text"],
            "requests": [["pid": 9, "name": "Nine"]], "sent": [["pid": 11, "username": "eleven"], ["name": "no pid"]]])
        let view = try XCTUnwrap(NextendoFriendsView.decode(data))
        XCTAssertEqual(view.friends, [NextendoFriend(pid: 7, name: "Seven", status: 2, titleID: "0100000000010000"),
                                      NextendoFriend(pid: 8, name: "eight", status: 2, titleID: nil)])
        XCTAssertEqual(view.requests.map(\.pid), [9])
        XCTAssertEqual(view.sent, [NextendoFriend(pid: 11, name: "eleven", status: 0, titleID: nil)])   // pending requests this account sent
        XCTAssertNil(NextendoFriendsView.decode(Data("[]".utf8)))
        let pictured = try XCTUnwrap(NextendoFriendsView.decode(try JSONSerialization.data(withJSONObject: ["friends": [
            ["pid": 12, "name": "Twelve", "avatar": "icon_03", "color": "#3a7bd5", "favorite": true, "friend_code": "SW-1234-5678-9012"],
            ["pid": 13, "name": "Thirteen", "avatar": "../etc", "color": "blue", "favorite": "yes", "friend_code": "1234"]]])))
        XCTAssertEqual(pictured.friends[0], NextendoFriend(pid: 12, name: "Twelve", status: 0, titleID: nil, avatar: "icon_03", color: "#3a7bd5",
                                                          favorite: true, friendCode: "SW-1234-5678-9012"))
        XCTAssertEqual(pictured.friends[0].avatarURL?.absoluteString, "https://nextendo.network/avatars/icon_03.jpg")
        XCTAssertEqual(pictured.friends[1], NextendoFriend(pid: 13, name: "Thirteen", status: 0, titleID: nil))   // malformed fields are dropped
        XCTAssertNil(NextendoFriendsView.decode(Data(#"{"requests":[]}"#.utf8)))
    }

    func testHubNotifiesOnlyWhatChangedAfterTheFirstSnapshot() async throws {
        let provider = Provider(), notifications = Notifications()
        provider.set(friends: [friend(7, "Seven", status: 1), friend(8, "Eight")], requests: [friend(9, "Nine")])
        let (hub, account) = hub(provider, store: HubStore(session(provider)), notifications: notifications)
        await hub.poll()                                   // what is already true is not news
        XCTAssertTrue(notifications.events.isEmpty)
        provider.set(friends: [friend(7, "Seven", status: 1), friend(8, "Eight", status: 2, title: "0100000000010000")],
                     requests: [friend(9, "Nine"), friend(10, "Ten")])
        await hub.poll()                                   // within the shared snapshot's age: nothing new is fetched
        XCTAssertTrue(notifications.events.isEmpty)
        provider.advance(20); await hub.poll()
        XCTAssertEqual(notifications.events, [.online(NextendoFriend(pid: 8, name: "Eight", status: 2, titleID: "0100000000010000"), game: "Synthetic Port"),
                                              .request(NextendoFriend(pid: 10, name: "Ten", status: 0, titleID: nil))])
        provider.advance(20); await hub.poll()
        XCTAssertEqual(notifications.events.count, 2)      // still online: no second notification
        _ = await account.accountDidChange()
        provider.set(friends: [friend(7, "Seven", status: 1), friend(11, "Eleven", status: 1)])
        provider.advance(20); await hub.poll()             // another account's first snapshot
        XCTAssertEqual(notifications.events.count, 2)
        XCTAssertEqual(provider.count("/api/session-status"), 0)   // no game open: no session check
        let latest = await hub.latest
        XCTAssertEqual(latest?.friends.map(\.pid), [7, 11])
    }

    func testNotificationsNeedPermissionAndTheSwitch() async throws {
        let provider = Provider(), notifications = Notifications(granted: false)
        provider.set(friends: [friend(7, "Seven")])
        let (hub, _) = hub(provider, store: HubStore(session(provider)), notifications: notifications, on: false)
        let granted = await hub.setNotifications(true)
        XCTAssertFalse(granted)
        let enabled = await hub.notificationsEnabled
        XCTAssertFalse(enabled)
        await hub.poll()
        provider.set(friends: [friend(7, "Seven", status: 1)]); provider.advance(20); await hub.poll()
        XCTAssertTrue(notifications.events.isEmpty)
    }

    func testRateLimitPausesThePolls() async throws {
        let provider = Provider()
        provider.set(friends: [], status: 429)
        let (hub, _) = hub(provider, store: HubStore(session(provider)))
        await hub.poll()
        for _ in 0..<4 { provider.advance(60); await hub.poll() }
        XCTAssertEqual(provider.count("/api/friends"), 1)
        provider.set(friends: []); provider.advance(60); await hub.poll()
        XCTAssertEqual(provider.count("/api/friends"), 2)
    }

    func testOnlyANewRevocationSignsThisMacOut() async throws {
        let provider = Provider(), notifications = Notifications(), ports = Ports(), store = HubStore(nil)
        try store.save(session(provider))
        let (hub, account) = hub(provider, store: store, notifications: notifications, ports: ports)
        let pushed = NSLock(); nonisolated(unsafe) var generations: [UInt64] = []
        account.notifier.set { value in pushed.withLock { generations.append(value) } }
        ports.set(1); provider.set(revoked: true)
        await hub.poll()                                   // an old closed session: not this one
        XCTAssertNotNil(try store.load())
        provider.set(revoked: false); provider.advance(60); await hub.poll()
        let check = try XCTUnwrap(provider.requests.last { $0.url?.path == "/api/session-status" })
        XCTAssertEqual(check.value(forHTTPHeaderField: "Authorization"), "Bearer " + (try store.load()?.token ?? ""))
        provider.set(revoked: true); provider.advance(60); await hub.poll()
        XCTAssertNil(try store.load())
        XCTAssertEqual(notifications.events, [.revoked])
        XCTAssertEqual(pushed.withLock { generations }, [2])
        let credential = await account.credential(renew: false)
        XCTAssertEqual(credential.status, .signedOut)
        ports.set(0); provider.advance(60); await hub.poll()
        XCTAssertEqual(provider.count("/api/session-status"), 3)
    }

    func testFriendCodesAreNormalizedAndSentToTheProvider() async throws {
        XCTAssertEqual(NextendoFriendCode.normalized("SW-3999-0628-0716"), "SW-3999-0628-0716")
        XCTAssertEqual(NextendoFriendCode.normalized(" 3999 0628 0716 "), "SW-3999-0628-0716")
        XCTAssertEqual(NextendoFriendCode.normalized("sw399906280716"), "SW-3999-0628-0716")
        XCTAssertNil(NextendoFriendCode.normalized("SW-3999-0628-071"))
        XCTAssertNil(NextendoFriendCode.normalized("3999-0628-0716; DROP"))
        XCTAssertNil(NextendoFriendCode.normalized("\u{0663}99906280716"))   // only ASCII digits
        let provider = Provider()
        let (hub, account) = hub(provider, store: HubStore(session(provider)))
        _ = await hub.friends()
        let sent = await account.sendFriendRequest("SW-3999-0628-0716")
        XCTAssertEqual(sent.status, .ok); XCTAssertEqual(sent.http, 200)
        let refused = await account.sendFriendRequest("3999 0628 0716")   // only the normalized form crosses to the provider
        XCTAssertEqual(refused.status, .refused)
        let posts = provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.url?.path ?? "" }, ["/api/friends"])
        XCTAssertEqual(posts.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }, [#"{"friend_code":"SW-3999-0628-0716"}"#])
        _ = await hub.friends()
        XCTAssertEqual(provider.count("/api/friends"), 3)   // the snapshot is fetched again after the request
    }

    func testFriendRequestAnswersGoToTheProvider() async throws {
        let provider = Provider()
        provider.set(friends: [], requests: [friend(9, "Nine")])
        let (hub, account) = hub(provider, store: HubStore(session(provider)))
        _ = await hub.friends()
        let accepted = await account.answerFriendRequest(9, accept: true)
        XCTAssertEqual(accepted.status, .ok); XCTAssertEqual(accepted.http, 200)
        let declined = await account.answerFriendRequest(10, accept: false)
        XCTAssertEqual(declined.http, 200)
        let refused = await account.answerFriendRequest(0, accept: true)
        XCTAssertEqual(refused.status, .refused)
        let posts = provider.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.url?.path ?? "" }, ["/api/friends/accept", "/api/friends/decline"])
        XCTAssertEqual(posts.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }, [#"{"pid":9}"#, #"{"pid":10}"#])
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
        _ = await hub.friends()
        XCTAssertEqual(provider.count("/api/friends"), 2)  // an answer drops the shared snapshot
    }

    func testNotificationTextFollowsTheLanguage() {
        let friend = NextendoFriend(pid: 1, name: "Seven", status: 2, titleID: nil)
        XCTAssertEqual(NextendoHubText.text(.online(friend, game: "Port"), languages: ["es-MX"]).body, "Está jugando a Port.")
        XCTAssertEqual(NextendoHubText.text(.online(friend, game: nil), languages: ["de", "fr-CA"]).body, "Est en ligne.")
        XCTAssertEqual(NextendoHubText.text(.request(friend), languages: ["zh-Hant"]).title, "Seven")
        XCTAssertEqual(NextendoHubText.text(.revoked, languages: ["ko"]).title, "Nextendo signed this Mac out")
    }

    func testAgentAppFindsTheStudioThatContainsIt() {
        let studio = URL(fileURLWithPath: "/Applications/NX Port Studio.app")
        XCTAssertEqual(NextendoAgentServer.studioBundle(containing: studio.appendingPathComponent(NextendoAgent.bundlePath))?.path, studio.path)
        XCTAssertNil(NextendoAgentServer.studioBundle(containing: URL(fileURLWithPath: "/tmp/NX Port Studio Agent.app")))
        XCTAssertNil(NextendoAgentServer.studioBundle(containing: URL(fileURLWithPath: "/usr/local/bin/NXPortStudioAgent")))
    }
}
