// Asset-free coordinator checks: synthetic accounts, local callbacks and signed
// test catalogs only. No Keychain, browser, HTTP server or device is accessed.
import Foundation
import CryptoKit

@_cdecl("dm_mobile_nextendo_use_keychain") func fixtureUseKeychain() {}
@_cdecl("dm_mobile_nextendo_routes_state") func fixtureRoutesState() -> Int32 { -1 }
@_cdecl("dm_mobile_nextendo_copy_legacy") func fixtureCopyLegacy(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int, _ size: UnsafeMutablePointer<Int>) -> Int32 { size.pointee = 0; return 0 }
@_cdecl("dm_mobile_nextendo_remove_legacy") func fixtureRemoveLegacy(_ expected: UnsafePointer<UInt8>?, _ size: Int) -> Int32 { 1 }

private final class FixtureStore: NextendoCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NextendoSession?
    func load() throws -> NextendoSession? { lock.withLock { value } }
    func save(_ session: NextendoSession) throws { lock.withLock { value = session } }
    func remove() throws { lock.withLock { value = nil } }
}
private actor FixtureHTTP: NextendoHTTPClient {
    private var replies: [NextendoHTTPResponse]
    init(_ replies: [NextendoHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> NextendoHTTPResponse {
        guard !replies.isEmpty else { throw NextendoError.requestFailed }
        return replies.removeFirst()
    }
}
private final class FixtureLegacy: MobileNextendoLegacyReading, @unchecked Sendable {
    var data: Data?
    var refuseRemoval = false
    init(_ data: Data?) { self.data = data }
    func load() -> Data? { data }
    func remove(matching expected: Data?) -> Bool {
        guard !refuseRemoval, expected == nil || expected == data else { return false }
        data = nil; return true
    }
}
@MainActor private final class FixtureBrowser: MobileNextendoBrowsing {
    enum Mode { case approve, pending, fail }
    var mode: Mode = .approve
    var scope = ""
    var receiver: MobileNextendoCallback?
    var callback: URL?
    func open(_ request: NextendoSignInRequest, receiver: MobileNextendoCallback) -> Bool {
        let query = URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        scope = query.first { $0.name == "scope" }!.value!
        var callback = URLComponents(string: "nxnative-nextendo://callback")!
        callback.queryItems = [.init(name: "state", value: query.first { $0.name == "state" }!.value!), .init(name: "code", value: "synthetic-code")]
        self.receiver = receiver; self.callback = callback.url!
        if mode == .approve { Task { await receiver.deliver(.success(callback.url!)) } }
        return mode != .fail
    }
    func cancel() {}
    func deliverLate() async { if let receiver, let callback { await receiver.deliver(.success(callback)) } }
}
@main private struct MobileNextendoCheck {
    @MainActor static func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Coordinator state did not settle")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["CFBundleIdentifier":"org.nxnative.fixture", "DMGameTitleID":"0000000000000042", "CFBundleShortVersionString":"3.0.5", "DMNextendoClientID":"nxnative-test-application"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = Bundle(path: directory.path)!
        let domain = "org.nxnative.tests.mobile-nextendo." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let now = Date(), key = Curve25519.Signing.PrivateKey()
        let formatter = ISO8601DateFormatter()
        let catalog: [String: Any] = ["document_type":"game_catalog", "schema_version":1, "revision":1,
            "issued_at":formatter.string(from: now.addingTimeInterval(-10)), "expires_at":formatter.string(from: now.addingTimeInterval(3600)),
            "games":[["title_ids":["0000000000000042"], "name":"Fixture", "enabled":true,
                      "required_capabilities":["versions.exact.v1"], "versions":["policy":"exact", "accepted":["4.0.1"]]]]]
        let payload = try JSONSerialization.data(withJSONObject: catalog)
        let envelope = try JSONSerialization.data(withJSONObject: ["key_id":"catalog-key-1", "payload":payload.base64EncodedString(), "signature":try key.signature(for: payload).base64EncodedString()])
        let catalogService = NextendoCatalogService(http: FixtureHTTP([.init(data: envelope, statusCode: 200), .init(data: Data(), statusCode: 503)]), cacheURL: nil, verifier: .init(publicKey: key.publicKey.rawRepresentation))
        let expiry = Int(now.addingTimeInterval(600).timeIntervalSince1970)
        let proof = "nx2." + Data("42.fixture.\(expiry)".utf8).nextendoBase64URL + "." + Data(repeating: 0, count: 32).nextendoBase64URL
        let token = Data(#"{"access_token":"synthetic-oauth","token_type":"Bearer","scope":"identity","expires_in":600}"#.utf8)
        let identity = Data(#"{"pid":42,"username":"fixture"}"#.utf8)
        let nex = try JSONSerialization.data(withJSONObject: ["nex_token":proof,"pid":42,"username":"fixture"])
        let store = FixtureStore(), callbacks = MobileNextendoCallbackPool(), browser = FixtureBrowser()
        let service = NextendoAccountService(store: store, http: FixtureHTTP([.init(data:token,statusCode:200), .init(data:identity,statusCode:200), .init(data:nex,statusCode:200)]), makeReceiver:{ callbacks.make() })
        let model = MobileNextendoModel(bundle: bundle, preferences: preferences, accountService: service, catalogService: catalogService, callbacks: callbacks, browser: browser)
        precondition(model.account == nil && !model.hasGameCredential && model.hasClientID)
        model.signIn()
        try await eventually { !model.isAuthorizing }
        precondition(model.account?.tokenKind == .oauth && !model.hasGameCredential && model.canRequestGameCredential)
        precondition(Set(browser.scope.split(separator: " ").map(String.init)) == Set(["identity", "friends", "presence", "game.matchmaking", "emulator.status"]))
        model.requestGameCredential()
        try await eventually { !model.isRequestingCredential }
        let storedNEX = try store.load()
        precondition(model.hasGameCredential && storedNEX?.tokenKind == .nex)
        await model.load()
        precondition(model.eligibility() == .versionNotAccepted(["4.0.1"]))
        model.updateRoutes(0)
        precondition(!model.mayAttemptGame, "A credential cannot override the signed version policy")
        await model.refreshCatalog()
        precondition(model.catalogError == .httpStatus(503) && model.catalog?.catalog != nil)
        let legacyData = try storedNEX!.encodedForStorage()
        let migratedKeychain = FixtureStore(), migratedLegacy = FixtureLegacy(legacyData)
        let migration = MobileNextendoCredentialStore(keychain: migratedKeychain, legacy: migratedLegacy, preferences: preferences)
        let migrated = try migration.load()
        let migratedSaved = try migratedKeychain.load()
        let canonicalLegacy = try NextendoSession.decodeStored(legacyData)
        precondition(migrated == canonicalLegacy && migratedSaved == canonicalLegacy && migratedLegacy.data == nil)
        let oauthStore = FixtureStore(), staleLegacy = FixtureLegacy(legacyData)
        let oauth = NextendoSession(tokenKind: .oauth, token: "synthetic-oauth", identity: nil, scopes: ["identity"], createdAt: now, expiresAt: now.addingTimeInterval(600))
        try oauthStore.save(oauth)
        let keepOAuth = MobileNextendoCredentialStore(keychain: oauthStore, legacy: staleLegacy, preferences: preferences)
        let preservedOAuth = try keepOAuth.load()
        precondition(preservedOAuth == oauth && staleLegacy.data != nil, "Legacy NEX must not overwrite current OAuth")
        staleLegacy.refuseRemoval = true
        do { try keepOAuth.remove(); preconditionFailure("Expected legacy removal failure") } catch {}
        let cannotResurrect = try keepOAuth.load()
        precondition(cannotResurrect == nil, "Sign-out must prevent legacy resurrection even after a removal failure")
        await model.signOut()
        let removed = try store.load()
        precondition(model.account == nil && removed == nil)

        let cancelledStore = FixtureStore(), cancelledCallbacks = MobileNextendoCallbackPool(), pendingBrowser = FixtureBrowser()
        pendingBrowser.mode = .pending
        let cancelledService = NextendoAccountService(store: cancelledStore, http: FixtureHTTP([.init(data:token,statusCode:200)]), makeReceiver:{ cancelledCallbacks.make() })
        let cancelled = MobileNextendoModel(bundle: bundle, preferences: preferences, accountService: cancelledService, catalogService: catalogService, callbacks: cancelledCallbacks, browser: pendingBrowser)
        cancelled.signIn()
        try await eventually { pendingBrowser.receiver != nil }
        cancelled.cancel()
        await pendingBrowser.deliverLate()
        try await Task.sleep(for: .milliseconds(20))
        let cancelledValue = try cancelledStore.load()
        precondition(!cancelled.isAuthorizing && cancelled.account == nil && cancelledValue == nil)
        pendingBrowser.mode = .approve
        cancelled.signIn()
        try await eventually { !cancelled.isAuthorizing }
        precondition(cancelled.account?.tokenKind == .oauth, "Retry must wait for the old cancellation barrier")
        await cancelled.signOut()

        let mismatchKeychain = FixtureStore(), mismatchLegacy = FixtureLegacy(legacyData)
        try mismatchKeychain.save(oauth)
        let mismatchStore = MobileNextendoCredentialStore(keychain: mismatchKeychain, legacy: mismatchLegacy, preferences: preferences)
        let wrongNEX = try JSONSerialization.data(withJSONObject: ["nex_token":proof,"pid":43,"username":"fixture"])
        let mismatchCallbacks = MobileNextendoCallbackPool()
        let mismatchService = NextendoAccountService(store: mismatchStore, http: FixtureHTTP([.init(data:identity,statusCode:200),.init(data:wrongNEX,statusCode:200)]), makeReceiver:{ mismatchCallbacks.make() })
        let mismatch = MobileNextendoModel(bundle: bundle, preferences: preferences, accountService: mismatchService, catalogService: catalogService, callbacks: mismatchCallbacks, browser: FixtureBrowser())
        await mismatch.load()
        mismatch.requestGameCredential()
        try await eventually { !mismatch.isRequestingCredential }
        let keptOAuth = try mismatchKeychain.load()
        precondition(mismatch.account?.tokenKind == .oauth && mismatch.accountError == .invalidResponse && keptOAuth == oauth, "A rejected NEX upgrade must retain scoped OAuth in Keychain")
        print("mobile Nextendo: account, NEX, signed version gate, refresh failure, cancel/late callback, retry and sign-out passed")
    }
}
