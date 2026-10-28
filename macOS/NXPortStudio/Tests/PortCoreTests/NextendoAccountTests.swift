import XCTest
@testable import PortCore

private final class MemoryNextendoStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NextendoSession?
    func load() throws -> NextendoSession? { lock.withLock { value } }
    func save(_ session: NextendoSession) throws { lock.withLock { value = session } }
    func remove() throws { lock.withLock { value = nil } }
}
private actor MockNextendoHTTP: NextendoHTTPClient {
    var requests: [URLRequest] = []
    var replies: [NextendoHTTPResponse]
    init(_ replies: [NextendoHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw NextendoError.requestFailed }
        return replies.removeFirst()
    }
    func count() -> Int { requests.count }
    func first() -> URLRequest? { requests.first }
}
private actor MockNextendoCallback: NextendoCallbackReceiver {
    let redirect = URL(string: "http://127.0.0.1:41923/callback")!
    var value: URL?
    var continuation: CheckedContinuation<URL, Error>?
    var cancelled = false
    func start() async throws -> URL { redirect }
    func callback() async throws -> URL {
        if let value { return value }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resolve(_ url: URL) { value = url; continuation?.resume(returning: url); continuation = nil }
    func cancel() async { cancelled = true; continuation?.resume(throwing: CancellationError()); continuation = nil }
}
private actor DelayedNEXUpgradeHTTP: NextendoHTTPClient {
    private var continuation: CheckedContinuation<NextendoHTTPResponse, Never>?
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        if request.url?.path == "/api/oauth/userinfo" { return .init(data: Data(#"{"pid":42,"username":"fixture"}"#.utf8), statusCode: 200) }
        return await withCheckedContinuation { continuation = $0 }
    }
    func waiting() -> Bool { continuation != nil }
    func resolve(_ data: Data) { continuation?.resume(returning: .init(data: data, statusCode: 200)); continuation = nil }
}

@MainActor final class NextendoAccountTests: XCTestCase {
    private func state(_ request: NextendoSignInRequest) -> String {
        URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
    }
    private func configuration() throws -> NextendoOAuthConfiguration { try .init(clientID: "nxnative-test-application") }
    func testStoredSchemaRoundtripAndCredentialIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = NextendoSession(tokenKind: .oauth, token: "synthetic-oauth", identity: nil, scopes: ["identity"], createdAt: now, expiresAt: now.addingTimeInterval(3600))
        let encoded = try oauth.encodedForStorage()
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(["schema_version", "token_kind", "token", "scopes", "created_at", "expires_at"]))
        XCTAssertEqual(try NextendoSession.decodeStored(encoded), oauth)
        XCTAssertFalse(try NextendoSession.decodeStored(encoded).summary(at: now).hasNEXCredential)
        let token = "nx2." + Data("42.fixture.1800003600".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        let mismatched = NextendoSession(tokenKind: .nex, token: token, identity: .init(pid: 42, username: "different"), scopes: [], createdAt: now, expiresAt: now.addingTimeInterval(3600))
        XCTAssertThrowsError(try NextendoSession.decodeStored(mismatched.encodedForStorage()))
    }
    func testFlatAndNestedNEXEndpointResponsesRequireIndependentIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = NextendoIdentity(pid: 42, username: "fixture", friendCode: "synthetic")
        let token = "nx2." + Data("42.fixture.1800003600".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        let account: [String: Any] = ["pid":42, "username":"fixture", "friend_code":"synthetic"]
        for body: [String: Any] in [["nex_token":token, "pid":42, "username":"fixture", "friend_code":"synthetic"], ["nex_token":token, "account":account]] {
            let data = try JSONSerialization.data(withJSONObject: body)
            XCTAssertEqual(try NextendoSession.decodeUserInfoResponse(data), identity)
            let result = try NextendoSession.decodeNEXCredentialResponse(data, identity: identity, now: now)
            XCTAssertTrue(result.summary(at: now).hasNEXCredential)
            XCTAssertEqual(try NextendoSession.decodeStored(result.encodedForStorage()), result)
            XCTAssertThrowsError(try NextendoSession.decodeNEXCredentialResponse(data, identity: .init(pid: 43, username: "fixture"), now: now))
        }
        for body: [String: Any] in [["nex_token":token, "pid":42, "username":"wrong"], ["nex_token":token, "pid":true, "username":"fixture"], ["nex_token":token, "username":"fixture"], ["access_token":token, "pid":42, "username":"fixture"], ["nex_token":token, "account":account, "pid":43, "username":"fixture"]] {
            XCTAssertThrowsError(try NextendoSession.decodeNEXCredentialResponse(JSONSerialization.data(withJSONObject: body), identity: identity, now: now))
        }
        let shorter = try JSONSerialization.data(withJSONObject: ["nex_token":token, "pid":42, "username":"fixture", "expires_in":60])
        XCTAssertEqual(try NextendoSession.decodeNEXCredentialResponse(shorter, identity: identity, now: now).expiresAt, now.addingTimeInterval(60))
    }
    func testUpgradeUsesUserinfoBeforeNEXAndPreservesOAuthOnMismatch() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = NextendoSession(tokenKind: .oauth, token: "synthetic-oauth", identity: nil, scopes: ["identity"], createdAt: now, expiresAt: now.addingTimeInterval(3600))
        let token = "nx2." + Data("42.fixture.1800003600".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        for returnedPID in [42,43] {
            let store = MemoryNextendoStore(); try store.save(oauth)
            let userinfo = Data(#"{"pid":42,"username":"fixture","friend_code":"synthetic"}"#.utf8)
            let nex = try JSONSerialization.data(withJSONObject: ["nex_token":token,"pid":returnedPID,"username":"fixture"])
            let http = MockNextendoHTTP([.init(data: userinfo, statusCode: 200), .init(data: nex, statusCode: 200)])
            let service = NextendoAccountService(store: store, http: http, now: { now })
            if returnedPID == 42 { let summary = try await service.upgradeGameCredential(); XCTAssertTrue(summary.hasNEXCredential) }
            else { do { _ = try await service.upgradeGameCredential(); XCTFail("identity mismatch accepted") } catch {}; XCTAssertEqual(try store.load(), oauth) }
            let first = await http.first(), count = await http.count()
            XCTAssertEqual(first?.url?.path, "/api/oauth/userinfo"); XCTAssertEqual(count,2)
        }
    }
    func testSignOutPreventsLateNEXUpgradeFromRestoringCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), store = MemoryNextendoStore(), http = DelayedNEXUpgradeHTTP()
        try store.save(.init(tokenKind: .oauth, token: "synthetic-oauth", identity: nil, scopes: ["identity"], createdAt: now, expiresAt: now.addingTimeInterval(3600)))
        let service = NextendoAccountService(store: store, http: http, now: { now })
        let upgrade = Task { try await service.upgradeGameCredential() }
        for _ in 0..<1000 { if await http.waiting() { break }; await Task.yield() }
        let waiting = await http.waiting(); XCTAssertTrue(waiting)
        try await service.signOut()
        let token = "nx2." + Data("42.fixture.1800003600".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        await http.resolve(try JSONSerialization.data(withJSONObject: ["nex_token":token,"pid":42,"username":"fixture"]))
        do { _ = try await upgrade.value; XCTFail("signed-out account restored by late response") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertNil(try store.load())
    }
    func testPKCERFC7636VectorAndConfiguration() throws {
        XCTAssertEqual(try NextendoPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertThrowsError(try NextendoPKCE.challenge(for: "short"))
        XCTAssertThrowsError(try NextendoOAuthConfiguration(clientID: ""))
        XCTAssertThrowsError(try NextendoOAuthConfiguration(clientID: "nextendo-emulator"))
        for url in ["http://nextendo.network", "https://other.example", "https://nextendo.network@other.example", "https://nextendo.network?token=bad"] {
            XCTAssertThrowsError(try NextendoOAuthConfiguration(clientID: "own-app", baseURL: URL(string: url)!))
        }
    }
    func testCallbackRejectsBadStateDuplicatesAndForeignEndpoints() throws {
        let redirect = URL(string: "http://127.0.0.1:43210/callback")!
        XCTAssertEqual(try NextendoAccountService.authorizationCode(callback: URL(string: "http://127.0.0.1:43210/callback?code=a%2Bb&state=expected")!, redirect: redirect, expectedState: "expected"), "a+b")
        for value in ["http://127.0.0.1:43210/callback?code=a&state=wrong",
                      "http://127.0.0.1:43210/callback?code=a&code=b&state=expected",
                      "http://127.0.0.1:43210/callback?code=a&state=expected&state=expected",
                      "http://127.0.0.1:43211/callback?code=a&state=expected",
                      "http://localhost:43210/callback?code=a&state=expected",
                      "http://user@127.0.0.1:43210/callback?code=a&state=expected",
                      "http://127.0.0.1:43210/callback?code=a&state=expected#fragment"] {
            XCTAssertThrowsError(try NextendoAccountService.authorizationCode(callback: URL(string: value)!, redirect: redirect, expectedState: "expected"))
        }
    }
    func testScopedOAuthIsNeverReportedAsNEXAndReplayDoesNotExchangeAgain() async throws {
        let callback = MockNextendoCallback(), store = MemoryNextendoStore()
        let http = MockNextendoHTTP([.init(data: Data(#"{"access_token":"scoped-fixture","token_type":"Bearer","scope":"identity friends","expires_in":3600}"#.utf8), statusCode: 200)])
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let service = NextendoAccountService(store: store, http: http, makeReceiver: { callback }, now: { fixed })
        let request = try await service.beginSignIn(configuration: configuration())
        let query = URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertFalse(query.contains { $0.name == "app" && $0.value == "ryujinx" })
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "nxnative-test-application")
        await callback.resolve(URL(string: "http://127.0.0.1:41923/callback?state=\(state(request))&code=one%2Btwo")!)
        let summary = try await service.finishSignIn(request.id)
        XCTAssertEqual(summary.tokenKind, .oauth); XCTAssertFalse(summary.hasNEXCredential)
        XCTAssertEqual(summary.expiresAt, fixed.addingTimeInterval(3600))
        let sent = await http.first()!
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Nextendo-Client-Id"), "nxnative-test-application")
        let fields = URLComponents(string: "https://example.test/?" + String(data: sent.httpBody!, encoding: .utf8)!)!.queryItems!
        XCTAssertEqual(fields.first { $0.name == "code" }?.value, "one+two")
        let verifier = fields.first { $0.name == "code_verifier" }!.value!
        XCTAssertEqual(try NextendoPKCE.challenge(for: verifier), query.first { $0.name == "code_challenge" }?.value)
        do { _ = try await service.finishSignIn(request.id); XCTFail("replayed request succeeded") }
        catch { XCTAssertEqual(error as? NextendoError, .authorizationUnavailable) }
        let count = await http.count(); XCTAssertEqual(count, 1)
        let session = try XCTUnwrap(store.load())
        XCTAssertFalse(String(describing: session).contains("scoped-fixture"))
        try await service.signOut(); XCTAssertNil(try store.load())
    }
    func testMismatchedStateNeverSendsRequestOrSavesCredential() async throws {
        let callback = MockNextendoCallback(), store = MemoryNextendoStore(), http = MockNextendoHTTP([])
        let service = NextendoAccountService(store: store, http: http, makeReceiver: { callback })
        let request = try await service.beginSignIn(configuration: configuration())
        await callback.resolve(URL(string: "http://127.0.0.1:41923/callback?state=wrong&code=unused")!)
        do { _ = try await service.finishSignIn(request.id); XCTFail("bad state accepted") }
        catch { XCTAssertEqual(error as? NextendoError, .callbackRejected) }
        let count = await http.count(); XCTAssertEqual(count, 0); XCTAssertNil(try store.load())
    }
    func testCancelledAttemptCannotSaveAnEventuallyReturnedResponse() async throws {
        let callback = MockNextendoCallback(), store = MemoryNextendoStore(), http = MockNextendoHTTP([])
        let service = NextendoAccountService(store: store, http: http, makeReceiver: { callback })
        let request = try await service.beginSignIn(configuration: configuration())
        let finishing = Task { try await service.finishSignIn(request.id) }
        await Task.yield(); await service.cancelSignIn()
        do { _ = try await finishing.value; XCTFail("cancelled authorization succeeded") } catch { }
        XCTAssertNil(try store.load())
    }
    func testNEXResponseAndErrorsStayDistinctFromWebsiteSessions() throws {
        let now = Date()
        let expiry = Int64(now.addingTimeInterval(3600).timeIntervalSince1970)
        let token = "nx2." + Data("42.fixture.\(expiry)".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        let data = try JSONSerialization.data(withJSONObject: ["nex_token": token, "account": ["pid": 42, "username": "fixture", "friend_code": "SW-TEST"]])
        let session = try NextendoSession.decodeTokenResponse(data, now: now)
        XCTAssertTrue(session.summary().hasNEXCredential); XCTAssertEqual(session.identity?.pid, 42)
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: Double(expiry)))
        XCTAssertThrowsError(try NextendoSession.decodeTokenResponse(Data(#"{"token":"web-session-fixture","account":{"pid":42}}"#.utf8), now: now))
        XCTAssertThrowsError(try NextendoSession.decodeTokenResponse(Data(#"{"nex_token":"not-a-nex-token","account":{"pid":42}}"#.utf8), now: now))
        XCTAssertThrowsError(try NextendoSession.decodeTokenResponse(Data(#"{"access_token":"opaque","token_type":"Bearer","expires_in":true}"#.utf8), now: now))
        XCTAssertThrowsError(try NextendoSession.decodeTokenResponse(Data(#"{"error":"sensitive-response-must-not-be-logged"}"#.utf8), now: now)) { error in
            XCTAssertFalse(error.localizedDescription.contains("sensitive-response"))
        }
    }
    func testNEXExpiryAndAccountBindingMustMatchResponse() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        for (pid, expiry) in [(UInt64(41), Int64(1_800_003_600)), (UInt64(42), Int64(1_799_999_999))] {
            let token = "nx2." + Data("\(pid).fixture.\(expiry)".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
            let data = try JSONSerialization.data(withJSONObject: ["nex_token": token, "account": ["pid": 42]])
            XCTAssertThrowsError(try NextendoSession.decodeTokenResponse(data, now: fixed))
        }
    }
    func testRejectedExchangeKeepsPreviousCredentialWithoutLoggingBody() async throws {
        let callback = MockNextendoCallback(), store = MemoryNextendoStore()
        let previous = NextendoSession(tokenKind: .oauth, token: "previous-synthetic-token", identity: nil, scopes: ["identity"], createdAt: Date(), expiresAt: nil)
        try store.save(previous)
        let http = MockNextendoHTTP([.init(data: Data("private-response-body".utf8), statusCode: 403)])
        let service = NextendoAccountService(store: store, http: http, makeReceiver: { callback })
        let request = try await service.beginSignIn(configuration: configuration())
        await callback.resolve(URL(string: "http://127.0.0.1:41923/callback?state=\(state(request))&code=unused")!)
        do { _ = try await service.finishSignIn(request.id); XCTFail("rejected token exchange succeeded") }
        catch {
            XCTAssertEqual(error as? NextendoError, .httpStatus(403))
            XCTAssertFalse(error.localizedDescription.contains("private-response-body"))
        }
        XCTAssertEqual(try store.load(), previous)
    }
    func testRealLoopbackBindsLocallyAndAcceptsSingleHTTPCallback() async throws {
        let server = try NextendoLoopbackServer()
        let redirect = try await server.start()
        XCTAssertEqual(redirect.host, "127.0.0.1"); XCTAssertGreaterThan(redirect.port ?? 0, 0)
        let invalid = URL(string: "http://127.0.0.1:\(redirect.port!)/elsewhere")!
        let (_, invalidResponse) = try await URLSession.shared.data(from: invalid)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
        let url = URL(string: redirect.absoluteString + "?state=fixture&code=fixture")!
        async let received = server.callback()
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let actual = try await received; XCTAssertEqual(actual, url)
        await server.cancel()
    }
    func testRealLoopbackCancellationReleasesCallbackWaiter() async throws {
        let server = try NextendoLoopbackServer()
        _ = try await server.start()
        let callback = Task { try await server.callback() }
        await server.cancel()
        do { _ = try await callback.value; XCTFail("cancelled listener returned a callback") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
