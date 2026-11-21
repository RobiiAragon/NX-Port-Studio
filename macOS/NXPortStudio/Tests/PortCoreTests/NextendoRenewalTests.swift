import Foundation
import XCTest
@testable import PortCore

private final class RenewalStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: NextendoSession?
    private var writes = 0
    private let gate: RenewalGate?
    init(_ session: NextendoSession?,gate: RenewalGate? = nil) { self.session = session; self.gate = gate }
    func load() throws -> NextendoSession? { lock.withLock { session } }
    func save(_ session: NextendoSession) throws { lock.withLock { self.session = session; writes += 1 } }
    func remove() throws { lock.withLock { session = nil } }
    func count() -> Int { lock.withLock { writes } }
    func external(_ next: NextendoSession) { lock.withLock { session = next } }
    func acquireExclusiveLease() async throws -> any NextendoCredentialLease {
        if let gate { await gate.wait() }
        return RenewalLease()
    }
}
private struct RenewalLease: NextendoCredentialLease { func release() {} }
private actor RenewalGate {
    var held = false
    private var released = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async {
        if released { return }
        held = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor RenewalHTTP: NextendoHTTPClient {
    private var replies: [NextendoHTTPResponse]
    private var requests: [URLRequest] = []
    private var hold: Int?
    private var continuation: CheckedContinuation<Void,Never>?
    init(_ replies: [NextendoHTTPResponse],hold: Int? = nil) { self.replies = replies; self.hold = hold }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        let index = requests.count; requests.append(request)
        guard !replies.isEmpty else { throw NextendoError.requestFailed }
        let reply = replies.removeFirst()
        if index == hold { hold = nil; await withCheckedContinuation { continuation = $0 } }
        return reply // Deliberately permits a late response after cancellation.
    }
    func held() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func paths() -> [String] { requests.map { $0.url!.path } }
    func form() -> [String:String] {
        guard let data = requests.first?.httpBody, let text = String(data:data,encoding:.utf8),
              let query = URLComponents(string: "https://fixture.invalid/?" + text) else { return [:] }
        return Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name,$0.value ?? "") })
    }
}
private actor LeaseState {
    var started = false, finished = false
    func start() { started = true }
    func finish() { finished = true }
}

@MainActor final class NextendoRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_000)
    private let scopes = ["identity","friends","game.matchmaking"]
    private func proof(_ expiry: Date, pid: UInt64 = 42) -> String {
        "nx2." + Data("\(pid).synthetic.\(Int64(expiry.timeIntervalSince1970))".utf8).nextendoBase64URL + "." + Data(repeating:0,count:32).nextendoBase64URL
    }
    private func session(accessExpired: Bool = true, legacy: Bool = false, proofExpired: Bool = true) -> NextendoSession {
        let expiry = now.addingTimeInterval(proofExpired ? -10 : 86000)
        let result = NextendoSession(tokenKind:.nex,token:proof(expiry),identity:.init(pid:42,username:"synthetic"),scopes:[],createdAt:now.addingTimeInterval(-1000),expiresAt:expiry)
        return result.withRenewal(legacy ? nil : .init(clientID:"nxnative-own-test-client",accessToken:"synthetic-access-old",refreshToken:"synthetic-refresh-old",expiresAt:now.addingTimeInterval(accessExpired ? -1 : 3500),scopes:scopes))
    }
    private func response(_ value: [String:Any],status: Int = 200) throws -> NextendoHTTPResponse {
        .init(data:try JSONSerialization.data(withJSONObject:value),statusCode:status)
    }
    private func replies(mintStatus: Int = 200, refresh: Bool = true) throws -> [NextendoHTTPResponse] {
        let token = try response(["access_token":"synthetic-access-new","refresh_token":"synthetic-refresh-new","token_type":"Bearer","expires_in":3600])
        let identity = try response(["pid":42,"username":"synthetic"])
        let nex = try response(["nex_token":proof(now.addingTimeInterval(86400)),"pid":42,"username":"synthetic","expires_in":86400],status:mintStatus)
        return (refresh ? [token] : []) + [identity,nex]
    }
    private func service(_ store: RenewalStore,_ http: RenewalHTTP) -> NextendoAccountService {
        let date = now
        return .init(store:store,http:http,makeReceiver:{ throw NextendoError.authorizationUnavailable },now:{ date })
    }
    private func waitHeld(_ http: RenewalHTTP) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while !(await http.held()) {
            guard ContinuousClock.now < deadline else { XCTFail("Synthetic transport did not reach its held response"); return }
            try await Task.sleep(for:.milliseconds(1))
        }
    }
    func testConcurrentPreparationRotatesOnceAndUsesTheDocumentedGrant() async throws {
        let store = RenewalStore(session()), http = RenewalHTTP(try replies(),hold:0), service = service(store,http)
        let workers = (0..<12).map { _ in Task { try await service.prepareGameAccount() } }
        try await waitHeld(http)
        XCTAssertEqual(store.count(),0)
        await http.release()
        for worker in workers { let result = try await worker.value; XCTAssertTrue(result?.hasNEXCredential == true) }
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.renewal?.refreshToken,"synthetic-refresh-new")
        XCTAssertEqual(saved.identity?.pid,42)
        XCTAssertEqual(store.count(),2,"One rotated-grant checkpoint and one final NEX write")
        let paths = await http.paths(), form = await http.form()
        XCTAssertEqual(paths,["/api/oauth/token","/api/oauth/userinfo","/api/nex-token"])
        XCTAssertEqual(form,["grant_type":"refresh_token","refresh_token":"synthetic-refresh-old","client_id":"nxnative-own-test-client"])
    }
    func testValidAccessFetchesOnlyTheNewGameProofAndLegacyExpiryStaysLinked() async throws {
        for force in [false,true] {
            let store = RenewalStore(session(accessExpired:false,proofExpired:!force)), http = RenewalHTTP(try replies(refresh:false))
            let result = try await service(store,http).prepareGameAccount(forceGameRefresh:force)
            XCTAssertTrue(result?.hasNEXCredential == true)
            let paths = await http.paths(); XCTAssertEqual(paths,["/api/oauth/userinfo","/api/nex-token"])
            XCTAssertEqual(store.count(),1)
        }
        let old = session(legacy:true), store = RenewalStore(old), http = RenewalHTTP([])
        let result = try await service(store,http).prepareGameAccount()
        XCTAssertEqual(result?.identity?.pid,42)
        XCTAssertTrue(result?.isExpired == true)
        XCTAssertEqual(try store.load(),old)
        let paths = await http.paths(); XCTAssertTrue(paths.isEmpty)
    }
    func testForcedPreparationCannotJoinAnUnforcedFreshnessSkip() async throws {
        let gate = RenewalGate(), store = RenewalStore(session(accessExpired:false,proofExpired:false),gate:gate)
        let http = RenewalHTTP(try replies(refresh:false)), service = service(store,http)
        let ordinary = Task { try await service.prepareGameAccount() }
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while !(await gate.held) {
            guard ContinuousClock.now < deadline else { XCTFail("Lease fixture was not reached"); return }
            try await Task.sleep(for:.milliseconds(1))
        }
        let forced = Task { try await service.prepareGameAccount(forceGameRefresh:true) }
        await Task.yield()
        await gate.release()
        _ = try await ordinary.value
        let result = try await forced.value, paths = await http.paths()
        XCTAssertEqual(paths,["/api/oauth/userinfo","/api/nex-token"])
        XCTAssertEqual(result?.expiresAt,now.addingTimeInterval(86400))
        XCTAssertEqual(store.count(),1)
    }
    func testRotatedGrantSurvivesLaterMintFailureWithoutChangingTheOldProof() async throws {
        let old = session(), store = RenewalStore(old)
        let http = RenewalHTTP(try replies(mintStatus:503) + replies(refresh:false)), service = service(store,http)
        do { _ = try await service.prepareGameAccount(); XCTFail("Mint rejection became successful renewal") }
        catch { XCTAssertEqual(error as? NextendoError,.accountHTTPStatus(.gameProof,503)) }
        let checkpoint = try XCTUnwrap(store.load())
        XCTAssertEqual(checkpoint.token,old.token)
        XCTAssertEqual(checkpoint.expiresAt,old.expiresAt)
        XCTAssertEqual(checkpoint.identity,old.identity)
        XCTAssertEqual(checkpoint.renewal?.refreshToken,"synthetic-refresh-new")
        XCTAssertEqual(store.count(),1)
        let renewed = try await service.prepareGameAccount()
        XCTAssertTrue(renewed?.hasNEXCredential == true)
        let paths = await http.paths(); XCTAssertEqual(paths.filter { $0 == "/api/oauth/token" }.count,1)
    }
    func testRejectedRefreshAndMalformedOrEscalatedRotationPreserveAllStorage() async throws {
        let old = session()
        let cases: [NextendoHTTPResponse] = [
            .init(data:Data("DO_NOT_DISPLAY_BODY".utf8),statusCode:401),
            .init(data:Data("DO_NOT_DISPLAY_BODY".utf8),statusCode:403),
            try response(["access_token":"synthetic-new","token_type":"Bearer","expires_in":3600]),
            try response(["access_token":"synthetic-new","refresh_token":"synthetic-new-refresh","token_type":"Bearer","expires_in":-1]),
            try response(["access_token":"synthetic-new","refresh_token":"synthetic-new-refresh","token_type":"Bearer","expires_in":3600,"scope":"identity friends game.matchmaking presence"])]
        for reply in cases {
            let store = RenewalStore(old), http = RenewalHTTP([reply])
            do { _ = try await service(store,http).prepareGameAccount(); XCTFail("Rejected or malformed refresh accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("DO_NOT_DISPLAY_BODY")) }
            XCTAssertEqual(try store.load(),old)
            XCTAssertEqual(store.count(),0)
        }
    }
    func testCancelAndSignOutCannotResurrectALateSuccessfulRefresh() async throws {
        for signOut in [false,true] {
            let old = session(), store = RenewalStore(old), http = RenewalHTTP(try replies(),hold:0), service = service(store,http)
            let worker = Task { try await service.prepareGameAccount() }
            try await waitHeld(http)
            if signOut { try await service.signOut() } else { await service.cancelSignIn() }
            await http.release()
            do { _ = try await worker.value; XCTFail("Cancelled refresh published success") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
            XCTAssertEqual(try store.load(),signOut ? nil : old)
            XCTAssertEqual(store.count(),0)
        }
    }
    func testIdentityMismatchAndAnExternallyChangedAccountDoNotCommit() async throws {
        let old = session(accessExpired:false)
        let wrong = try response(["pid":43,"username":"synthetic"])
        let mismatchStore = RenewalStore(old), mismatchHTTP = RenewalHTTP([wrong])
        do { _ = try await service(mismatchStore,mismatchHTTP).prepareGameAccount(); XCTFail("Other identity accepted") }
        catch { XCTAssertEqual(error as? NextendoError,.invalidResponse) }
        XCTAssertEqual(try mismatchStore.load(),old)
        let store = RenewalStore(old), http = RenewalHTTP(try replies(refresh:false),hold:1), service = service(store,http)
        let worker = Task { try await service.prepareGameAccount() }
        try await waitHeld(http)
        let other = NextendoSession(tokenKind:.nex,token:proof(now.addingTimeInterval(1000),pid:43),identity:.init(pid:43,username:"synthetic"),scopes:[],createdAt:now,expiresAt:now.addingTimeInterval(1000))
        store.external(other); await http.release()
        do { _ = try await worker.value; XCTFail("Newer account overwritten") } catch { XCTAssertEqual(error as? NextendoError,.authorizationUnavailable) }
        XCTAssertEqual(try store.load(),other)
        XCTAssertEqual(store.count(),0)
    }
    func testSharedLeaseRejectsUnsafeFilesAndCancelsAContendedWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("symlink")
        try Data().write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        do { _ = try await NextendoFileCredentialLease.acquire(at:link); XCTFail("Symlink lease accepted") } catch { }
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:target.path)
        do { _ = try await NextendoFileCredentialLease.acquire(at:target); XCTFail("Loose lease permissions accepted") } catch { }
        let good = root.appendingPathComponent("account.lock")
        let owner = try await NextendoFileCredentialLease.acquire(at:good), state = LeaseState()
        do {
            _ = try await NextendoFileCredentialLease.acquire(at:good,waitTimeout:.milliseconds(50))
            XCTFail("A held lease unexpectedly became available")
        } catch {
            XCTAssertEqual(error as? NextendoError,.credentialBusy)
            XCTAssertTrue((error as? NextendoError)?.permitsBackgroundRetry == true)
        }
        let waiting = Task {
            await state.start()
            do {
                let lease = try await NextendoFileCredentialLease.acquire(at:good); lease.release()
                await state.finish(); return false
            } catch is CancellationError { await state.finish(); return true }
            catch { await state.finish(); return false }
        }
        while !(await state.started) { await Task.yield() }
        waiting.cancel()
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while !(await state.finished), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(1)) }
        let cancelledBeforeRelease = await state.finished
        owner.release()
        XCTAssertTrue(cancelledBeforeRelease,"Cancellation must finish without waiting for the other owner")
        let cancelled = await waiting.value; XCTAssertTrue(cancelled)
    }
}
