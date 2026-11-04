// Production coordinators with synthetic stores, HTTP and callbacks only.
// No browser, Keychain item or authenticated service request is accessed.
import Foundation
import XCTest
@testable import PortCore
@testable import PortStudio

private final class GameSignInStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NextendoSession?
    private var writes = 0
    init(_ value: NextendoSession?) { self.value = value }
    func load() throws -> NextendoSession? { lock.withLock { value } }
    func save(_ session: NextendoSession) throws { lock.withLock { value = session; writes += 1 } }
    func remove() throws { lock.withLock { value = nil } }
    func writeCount() -> Int { lock.withLock { writes } }
    func replaceExternally(_ session: NextendoSession) { lock.withLock { value = session } }
}
private final class GameSignInClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
private actor GameSignInHTTP: NextendoHTTPClient {
    private var replies: [NextendoHTTPResponse]
    private var paths: [String] = []
    private var holdAt: Int?
    private let failAt: Int?
    private var held: CheckedContinuation<Void, Never>?
    init(_ replies: [NextendoHTTPResponse], holdAt: Int? = nil, failAt: Int? = nil) {
        self.replies = replies; self.holdAt = holdAt; self.failAt = failAt
    }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        let index = paths.count
        paths.append(request.url!.path)
        guard !replies.isEmpty else { throw NextendoError.requestFailed }
        let response = replies.removeFirst()
        if index == holdAt {
            holdAt = nil
            // Deliberately deliver even after cancellation: production must
            // reject a stale successful HTTP response before committing it.
            await withCheckedContinuation { held = $0 }
        }
        if index == failAt { throw NextendoError.requestFailed }
        return response
    }
    func requestedPaths() -> [String] { paths }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
}
private actor GameSignInCallback: NextendoCallbackReceiver {
    private var value: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    func start() async throws -> URL { URL(string: "http://127.0.0.1:41923/callback")! }
    func callback() async throws -> URL {
        if let value { return value }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resolve(_ value: URL) { self.value = value; continuation?.resume(returning: value); continuation = nil }
    func cancel() async { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
private final class GameSignInCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: GameSignInCallback?
    func make() -> GameSignInCallback {
        lock.withLock { let callback = GameSignInCallback(); latest = callback; return callback }
    }
    func current() -> GameSignInCallback? { lock.withLock { latest } }
}

@MainActor
final class NextendoGameSignInTests: XCTestCase {
    private func proof(_ pid: UInt64, _ name: String, now: Date) -> String {
        "nx2." + Data("\(pid).\(name).\(Int64(now.timeIntervalSince1970) + 3600)".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
    }
    private func previous(now: Date) -> NextendoSession {
        .init(tokenKind: .nex, token: proof(41, "synthetic_old", now: now), identity: .init(pid: 41, username: "synthetic_old"),
              scopes: [], createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(3500))
    }
    private func replies(now: Date, nexStatus: Int = 200) throws -> [NextendoHTTPResponse] {
        let oauth = Data(#"{"access_token":"synthetic-oauth-grant","token_type":"Bearer","scope":"identity friends","expires_in":3600}"#.utf8)
        let userinfo = Data(#"{"pid":42,"username":"synthetic_new"}"#.utf8)
        let nex = try JSONSerialization.data(withJSONObject: ["nex_token":proof(42,"synthetic_new",now: now),"pid":42,"username":"synthetic_new"])
        return [.init(data: oauth,statusCode: 200), .init(data: userinfo,statusCode: 200), .init(data: nex,statusCode: nexStatus)]
    }
    private func model(store: GameSignInStore, http: GameSignInHTTP, now: Date, clock: GameSignInClock? = nil) -> StudioModel {
        let callbacks = GameSignInCallbacks(), clock = clock ?? GameSignInClock(now)
        let service = NextendoAccountService(store: store, http: http, makeReceiver: { callbacks.make() }, now: { clock.now() })
        let suite = "org.nxnative.tests.game-sign-in." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let model = StudioModel(nextendoPreferences: preferences, nextendoAccountService: service, nextendoBrowserOpener: { url in
            guard let callback = callbacks.current() else { return false }
            let state = URLComponents(url: url,resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            Task { await callback.resolve(URL(string: "http://127.0.0.1:41923/callback?code=synthetic-code&state=" + state)!) }
            return true
        })
        model.nextendoClientID = "nxnative-own-test-client"
        model.nextendoAccount = try? store.load()?.summary(at: now)
        return model
    }
    private func waitUntilHeld(_ http: GameSignInHTTP) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await http.isHeld()) {
            guard ContinuousClock.now < deadline else { XCTFail("HTTP fixture did not reach the held response"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func testOneSignInFinishesOnlyAfterGameProofIsSaved() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let http = GameSignInHTTP(try replies(now: now)), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn()
        await model.nextendoAuthorizationTask?.value
        let saved = try XCTUnwrap(store.load())
        // Optional private interop receipt contains only these synthetic values.
        if let out = ProcessInfo.processInfo.environment["NX_SIGNIN_INTEROP_OUT"] {
            try old.encodedForStorage().write(to: URL(fileURLWithPath: out + ".old.json"))
            try saved.encodedForStorage().write(to: URL(fileURLWithPath: out + ".active.json"))
        }
        XCTAssertEqual(saved.tokenKind,.nex)
        XCTAssertEqual(saved.identity?.pid,42)
        XCTAssertEqual(model.nextendoAccount?.hasNEXCredential,true)
        XCTAssertNil(model.nextendoAccountError)
        XCTAssertEqual(store.writeCount(),1)
        let paths = await http.requestedPaths()
        XCTAssertEqual(paths,["/api/oauth/token","/api/oauth/userinfo","/api/nex-token"])
    }
    func testDirectProviderNEXResponseNeedsNoSecondExchange() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let data = try JSONSerialization.data(withJSONObject: ["nex_token":proof(42,"synthetic_new",now: now),
            "account":["pid":42,"username":"synthetic_new"]])
        let http = GameSignInHTTP([.init(data:data,statusCode:200)]), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn(); await model.nextendoAuthorizationTask?.value
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.tokenKind,.nex)
        XCTAssertEqual(saved.identity?.pid,42)
        XCTAssertEqual(store.writeCount(),1)
        XCTAssertTrue(model.nextendoAccount?.hasNEXCredential == true)
        XCTAssertNil(model.nextendoAccountError)
        let paths = await http.requestedPaths()
        XCTAssertEqual(paths,["/api/oauth/token"])
        if let out = ProcessInfo.processInfo.environment["NX_SIGNIN_INTEROP_OUT"] {
            try old.encodedForStorage().write(to: URL(fileURLWithPath: out + ".direct.old.json"))
            try saved.encodedForStorage().write(to: URL(fileURLWithPath: out + ".direct.active.json"))
        }
    }
    func testRejectedGameCredentialPreservesExistingNativeProof() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let http = GameSignInHTTP(try replies(now: now,nexStatus: 401)), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn()
        await model.nextendoAuthorizationTask?.value
        XCTAssertEqual(try store.load(),old)
        XCTAssertEqual(model.nextendoAccount?.identity?.pid,41)
        XCTAssertNotNil(model.nextendoAccountError)
        XCTAssertFalse(model.isAuthorizingNextendo)
        XCTAssertEqual(store.writeCount(),0)
    }
    func testIncompleteExchangeKeepsPreviousProofUntilTheSingleFinalWrite() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let http = GameSignInHTTP(try replies(now: now),holdAt: 2), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn()
        try await waitUntilHeld(http)
        XCTAssertEqual(try store.load(),old)
        XCTAssertEqual(store.writeCount(),0)
        XCTAssertTrue(model.isAuthorizingNextendo)
        XCTAssertEqual(model.nextendoAccount?.identity?.pid,41)
        await http.release()
        await model.nextendoAuthorizationTask?.value
        XCTAssertEqual(store.writeCount(),1)
        XCTAssertEqual(model.nextendoAccount?.identity?.pid,42)
    }
    func testEveryRejectedExchangePreservesStorageWithoutRestoringOverIt() async throws {
        let now = Date(), old = previous(now: now), good = try replies(now: now)
        var cases: [(String,[NextendoHTTPResponse])] = []
        for stage in 0...2 {
            var failed = good; failed[stage] = .init(data: Data(),statusCode: 401)
            cases.append(("HTTP rejection at stage \(stage)",failed))
            var malformed = good; malformed[stage] = .init(data: Data("{}".utf8),statusCode: 200)
            cases.append(("Malformed response at stage \(stage)",malformed))
        }
        var noIdentity = good
        noIdentity[0] = .init(data: Data(#"{"access_token":"synthetic-oauth","token_type":"Bearer","scope":"friends","expires_in":3600}"#.utf8),statusCode: 200)
        cases.append(("Missing identity scope",noIdentity))
        for identity in [["pid":43,"username":"synthetic_new"], ["pid":42,"username":"different_name"]] as [[String:Any]] {
            var mismatch = good
            var response = identity; response["nex_token"] = proof(42,"synthetic_new",now: now)
            mismatch[2] = .init(data: try JSONSerialization.data(withJSONObject: response),statusCode: 200)
            cases.append(("Incoherent game identity",mismatch))
        }
        var expired = good
        expired[2] = .init(data: try JSONSerialization.data(withJSONObject: ["nex_token":proof(42,"synthetic_new",now: now.addingTimeInterval(-7200)),"pid":42,"username":"synthetic_new"]),statusCode: 200)
        cases.append(("Expired game proof",expired))
        for (name,responses) in cases {
            let store = GameSignInStore(old), http = GameSignInHTTP(responses)
            let model = model(store: store,http: http,now: now)
            model.beginNextendoSignIn(); await model.nextendoAuthorizationTask?.value
            XCTAssertEqual(try store.load(),old,name)
            XCTAssertEqual(store.writeCount(),0,name)
            XCTAssertEqual(model.nextendoAccount?.identity?.pid,41,name)
            XCTAssertNotNil(model.nextendoAccountError,name)
            XCTAssertFalse(model.isAuthorizingNextendo,name)
        }
        for stage in 0...2 {
            let store = GameSignInStore(old), http = GameSignInHTTP(good,failAt: stage)
            let model = model(store: store,http: http,now: now)
            model.beginNextendoSignIn(); await model.nextendoAuthorizationTask?.value
            XCTAssertEqual(try store.load(),old)
            XCTAssertEqual(store.writeCount(),0)
            XCTAssertNotNil(model.nextendoAccountError)
        }
    }
    func testOAuthExpiryDuringTheFetchCannotCommitItsLateGameProof() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old), clock = GameSignInClock(now)
        let http = GameSignInHTTP(try replies(now: now),holdAt: 2), model = model(store: store,http: http,now: now,clock: clock)
        model.beginNextendoSignIn(); try await waitUntilHeld(http)
        clock.advance(3601)
        await http.release(); await model.nextendoAuthorizationTask?.value
        XCTAssertEqual(try store.load(),old)
        XCTAssertEqual(store.writeCount(),0)
        XCTAssertNotNil(model.nextendoAccountError)
    }
    func testAnotherAccountStoredDuringTheFetchIsNeverOverwritten() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let newer = NextendoSession(tokenKind: .nex,token: proof(43,"synthetic_other",now: now),identity: .init(pid: 43,username: "synthetic_other"),scopes: [],createdAt: now,expiresAt: now.addingTimeInterval(3500))
        let http = GameSignInHTTP(try replies(now: now),holdAt: 2), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn(); try await waitUntilHeld(http)
        store.replaceExternally(newer)
        await http.release(); await model.nextendoAuthorizationTask?.value
        XCTAssertEqual(try store.load(),newer)
        XCTAssertEqual(store.writeCount(),0)
        XCTAssertNotNil(model.nextendoAccountError)
        XCTAssertNotEqual(model.nextendoAccount?.identity?.pid,42)
    }
    func testCancelAndImmediateRetryRejectsTheOldSuccessfulResponse() async throws {
        let now = Date(), old = previous(now: now), store = GameSignInStore(old)
        let responses = try replies(now: now)
        let http = GameSignInHTTP(responses + responses,holdAt: 2), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn(); try await waitUntilHeld(http)
        let cancelled = model.nextendoAuthorizationTask
        model.cancelNextendoSignIn(); model.beginNextendoSignIn()
        XCTAssertEqual(try store.load(),old)
        XCTAssertEqual(store.writeCount(),0)
        await http.release(); await cancelled?.value; await model.nextendoAuthorizationTask?.value
        XCTAssertEqual(store.writeCount(),1)
        XCTAssertEqual(model.nextendoAccount?.identity?.pid,42)
        XCTAssertNil(model.nextendoAccountError)
        let paths = await http.requestedPaths()
        XCTAssertEqual(paths.count,6)
    }
    func testRequestedScopesMatchReviewedProviderContract() {
        XCTAssertEqual(StudioModel.nextendoScopes,["identity","friends","game.matchmaking"])
    }
    func testDocumentedSignInRetainsTheRotatingRefreshGrant() async throws {
        let now = Date(), store = GameSignInStore(previous(now: now))
        var responses = try replies(now: now)
        responses[0] = .init(data: Data(#"{"access_token":"synthetic-oauth-grant","refresh_token":"synthetic-refresh-grant","token_type":"Bearer","scope":"identity friends game.matchmaking","expires_in":3600}"#.utf8),statusCode: 200)
        let http = GameSignInHTTP(responses), model = model(store: store,http: http,now: now)
        model.beginNextendoSignIn(); await model.nextendoAuthorizationTask?.value
        let saved = try XCTUnwrap(store.load())
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.encodedForStorage()) as? [String:Any])
        let renewal = try XCTUnwrap(record["renewal"] as? [String:Any],"The documented refresh credential must survive the game-proof exchange")
        XCTAssertEqual(renewal["refresh_token"] as? String,"synthetic-refresh-grant")
        XCTAssertEqual(renewal["client_id"] as? String,"nxnative-own-test-client")
        XCTAssertEqual(saved.tokenKind,.nex)
    }
    func testInitialOAuthMayOmitUnchangedScopesButCannotEscalateThem() async throws {
        for escalated in [false,true] {
            let now = Date(), old = previous(now:now), store = GameSignInStore(old)
            var token: [String:Any] = ["access_token":"synthetic-access","refresh_token":"synthetic-refresh","token_type":"Bearer","expires_in":3600]
            if escalated { token["scope"] = "identity friends game.matchmaking presence" }
            var responses = try replies(now:now)
            responses[0] = .init(data:try JSONSerialization.data(withJSONObject:token),statusCode:200)
            let http = GameSignInHTTP(responses), model = model(store:store,http:http,now:now)
            model.beginNextendoSignIn(); await model.nextendoAuthorizationTask?.value
            let saved = try XCTUnwrap(store.load()), paths = await http.requestedPaths()
            if escalated {
                XCTAssertEqual(saved,old)
                XCTAssertEqual(store.writeCount(),0)
                XCTAssertEqual(paths.count,1)
                XCTAssertNotNil(model.nextendoAccountError)
            } else {
                XCTAssertEqual(saved.renewal?.scopes,["identity","friends","game.matchmaking"])
                XCTAssertEqual(saved.tokenKind,.nex)
                XCTAssertNil(model.nextendoAccountError)
            }
            model.nextendoRenewalTask?.cancel()
        }
    }
    func testHTTPFailureIdentifiesTheActualAccountStepWithoutTheBody() async throws {
        let now = Date()
        for (index,step) in [NextendoAccountStep.codeExchange,.identity,.gameProof].enumerated() {
            var responses = try replies(now: now)
            responses[index] = .init(data:Data("DO_NOT_DISPLAY_BODY_OR_CREDENTIAL".utf8),statusCode:403)
            let http = GameSignInHTTP(responses), callback = GameSignInCallback()
            let service = NextendoAccountService(store:GameSignInStore(previous(now:now)),http:http,makeReceiver:{ callback },now:{ now })
            let request = try await service.beginSignIn(configuration:.init(clientID:"nxnative-own-test-client"))
            let state = URLComponents(url:request.authorizationURL,resolvingAgainstBaseURL:false)!.queryItems!.first { $0.name == "state" }!.value!
            await callback.resolve(URL(string:"http://127.0.0.1:41923/callback?code=synthetic&state="+state)!)
            do { _ = try await service.finishSignIn(request.id,forGames:true); XCTFail("HTTP403 accepted") }
            catch {
                XCTAssertEqual(error as? NextendoError,.accountHTTPStatus(step,403))
                XCTAssertFalse(error.localizedDescription.contains("DO_NOT_DISPLAY"))
            }
        }
    }
    func testExpiredIdentityStaysVisibleWhileRenewingAndAfterRenewalIsRefused() async throws {
        for status in [200,403] {
            let now = Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970))
            let grant = NextendoRenewalGrant(clientID:"nxnative-own-test-client",accessToken:"synthetic-old-access",refreshToken:"synthetic-old-refresh",expiresAt:now.addingTimeInterval(-1),scopes:["identity","friends","game.matchmaking"])
            let old = NextendoSession(tokenKind:.nex,token:proof(42,"synthetic_new",now:now.addingTimeInterval(-7200)),identity:.init(pid:42,username:"synthetic_new"),scopes:[],createdAt:now.addingTimeInterval(-10800),expiresAt:now.addingTimeInterval(-3600)).withRenewal(grant)
            let store = GameSignInStore(old)
            var responses = try replies(now:now)
            responses[0] = .init(data:Data(#"{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8),statusCode:status)
            let http = GameSignInHTTP(responses,holdAt:0), model = model(store:store,http:http,now:now)
            let loading = Task { await model.reloadNextendoAccount() }
            try await waitUntilHeld(http)
            XCTAssertEqual(model.nextendoAccount?.identity?.pid,42)
            XCTAssertTrue(model.nextendoAccount?.isExpired == true)
            await http.release(); await loading.value
            XCTAssertEqual(model.nextendoAccount?.identity?.pid,42)
            if status == 200 {
                XCTAssertTrue(model.nextendoAccount?.hasNEXCredential == true)
                XCTAssertNil(model.nextendoAccountError)
            } else {
                XCTAssertTrue(model.nextendoAccount?.isExpired == true)
                XCTAssertNotNil(model.nextendoAccountError)
                XCTAssertEqual(try store.load(),old)
            }
            model.nextendoRenewalTask?.cancel()
        }
    }
}
