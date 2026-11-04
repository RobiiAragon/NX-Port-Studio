import Foundation
import CryptoKit
import Security
import Darwin

public enum NextendoError: LocalizedError, Equatable, Sendable {
    case registrationRequired, invalidConfiguration, callbackRejected, authorizationUnavailable
    case authorizationExpired, authorizationDenied, invalidResponse, requestFailed
    case httpStatus(Int), keychain(Int32)
    case accountHTTPStatus(NextendoAccountStep, Int)
    case credentialBusy
    public var permitsBackgroundRetry: Bool {
        switch self {
        case .requestFailed, .credentialBusy: true
        case .accountHTTPStatus(_,let status), .httpStatus(let status): status == 408 || status == 429 || (500...599).contains(status)
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .registrationRequired: return "Register NXNative's own Nextendo application and enter its client ID first."
        case .invalidConfiguration: return "The Nextendo application configuration is invalid."
        case .callbackRejected: return "The Nextendo sign-in callback could not be verified. Start sign-in again."
        case .authorizationUnavailable: return "This Nextendo sign-in request has already finished or was cancelled."
        case .authorizationExpired: return "The Nextendo sign-in request expired. Start sign-in again."
        case .authorizationDenied: return "Nextendo sign-in was declined."
        case .invalidResponse: return "Nextendo returned an unsupported account response. No credential was saved."
        case .requestFailed: return "The Nextendo service could not be reached."
        case .httpStatus(let code): return "Nextendo returned HTTP \(code)."
        case .keychain(let status): return "The Nextendo credential could not be accessed in Keychain (\(status))."
        case .accountHTTPStatus(let step, let status): return String(format: step.messageFormat, status)
        case .credentialBusy: return "Another app is renewing the saved Nextendo account. Try again shortly."
        }
    }
}

public enum NextendoAccountStep: String, Sendable {
    case codeExchange, identity, gameProof, refresh
    public var messageFormat: String {
        switch self {
        case .codeExchange: "Nextendo could not exchange the sign-in code (HTTP %d)."
        case .identity: "Nextendo could not verify the account identity (HTTP %d)."
        case .gameProof: "Nextendo could not issue the game credential (HTTP %d)."
        case .refresh: "Nextendo could not renew sign-in (HTTP %d)."
        }
    }
}

public struct NextendoHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int) { self.data = data; self.statusCode = statusCode }
}

public protocol NextendoHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse
}

private final class NextendoNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Uses normal system TLS verification, an ephemeral session and no credential-bearing redirects.
public struct NextendoURLSessionClient: NextendoHTTPClient {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NextendoNoRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextendoError.invalidResponse }
        return NextendoHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

public struct NextendoOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let baseURL: URL
    public let scopes: [String]
    public init(clientID: String, baseURL: URL = URL(string: "https://nextendo.network")!,
                scopes: [String] = ["identity", "friends"]) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw NextendoError.registrationRequired }
        guard id.count <= 256, id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              id != "nextendo-emulator", id != "unregistered",
              let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "nextendo.network",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, parts.path.isEmpty || parts.path == "/",
              !scopes.isEmpty, scopes.count <= 32, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ $0.range(of: "^[A-Za-z0-9:._-]{1,64}$", options: .regularExpression) != nil }) else {
            throw NextendoError.invalidConfiguration
        }
        self.clientID = id; self.baseURL = baseURL; self.scopes = scopes
    }
}

public enum NextendoPKCE {
    public static func challenge(for verifier: String) throws -> String {
        guard verifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil else {
            throw NextendoError.invalidConfiguration
        }
        return Data(SHA256.hash(data: Data(verifier.utf8))).nextendoBase64URL
    }
    static func randomString(bytes count: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NextendoError.requestFailed
        }
        return Data(bytes).nextendoBase64URL
    }
}

extension Data {
    var nextendoBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(nextendoBase64URL value: String) {
        guard !value.isEmpty, value.range(of: "^[A-Za-z0-9_-]+={0,2}$", options: .regularExpression) != nil else { return nil }
        let raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
    }
}

public enum NextendoTokenKind: String, Codable, Sendable { case nex, oauth }

// Kept only inside the encrypted account record. Never exposed in summaries,
// environment, game bundles or the C credential provider's NEX proof.
struct NextendoRenewalGrant: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case clientID = "clientId", accessToken, refreshToken, expiresAt, scopes }
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: [String]
    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
    func validate() throws {
        _ = try NextendoOAuthConfiguration(clientID: clientID, scopes: scopes)
        guard Self.validToken(accessToken), Self.validToken(refreshToken), expiresAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970 > 0 else { throw NextendoError.invalidResponse }
    }
}

public struct NextendoIdentity: Codable, Equatable, Sendable {
    public let pid: UInt64?
    public let username: String?
    public let friendCode: String?
    public init(pid: UInt64? = nil, username: String? = nil, friendCode: String? = nil) {
        self.pid = pid; self.username = username; self.friendCode = friendCode
    }
}

/// A token's kind describes the service response; it does not claim NEX connectivity or local signature verification.
public struct NextendoSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let schemaVersion: Int
    public let tokenKind: NextendoTokenKind
    public let token: String
    public let identity: NextendoIdentity?
    public let scopes: [String]
    public let createdAt: Date
    public let expiresAt: Date?
    var renewal: NextendoRenewalGrant?
    public init(tokenKind: NextendoTokenKind, token: String, identity: NextendoIdentity?, scopes: [String], createdAt: Date, expiresAt: Date?) {
        schemaVersion = 1; self.tokenKind = tokenKind; self.token = token; self.identity = identity
        self.scopes = scopes; self.createdAt = createdAt; self.expiresAt = expiresAt
        renewal = nil
    }
    public var description: String { "<NextendoSession \(tokenKind.rawValue); credential redacted>" }
    public var debugDescription: String { description }
    public func summary(at now: Date = Date()) -> NextendoAccountSummary {
        NextendoAccountSummary(tokenKind: tokenKind, identity: identity, scopes: scopes, expiresAt: expiresAt,
                               isExpired: expiresAt.map { $0 <= now } ?? false,
                               renewalCheckAt: renewal.map { min($0.expiresAt.addingTimeInterval(-60), (expiresAt ?? $0.expiresAt).addingTimeInterval(-300)) })
    }
    func withRenewal(_ grant: NextendoRenewalGrant?) -> Self { var next = self; next.renewal = grant; return next }
    static func decodeTokenResponse(_ data: Data, now: Date, clientID: String? = nil, previousScopes: [String]? = nil) throws -> NextendoSession {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NextendoError.invalidResponse }
        let nex = object["nex_token"] as? String, oauth = object["access_token"] as? String
        guard (nex != nil) != (oauth != nil), let token = nex ?? oauth,
              !token.isEmpty, token.utf8.count <= 16_384, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw NextendoError.invalidResponse }
        let kind: NextendoTokenKind = nex == nil ? .oauth : .nex
        let nexClaims = kind == .nex ? try Self.nexClaims(token) : nil
        if kind == .oauth && (object["token_type"] as? String)?.lowercased() != "bearer" { throw NextendoError.invalidResponse }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let identityObject = object["account"] as? [String: Any]
        let identity = try identityObject.map { try decoder.decode(NextendoIdentity.self, from: JSONSerialization.data(withJSONObject: $0)) }
        if kind == .nex && identity?.pid != nexClaims?.pid { throw NextendoError.invalidResponse }
        if let username = identity?.username, kind == .nex, username != nexClaims?.username { throw NextendoError.invalidResponse }
        var expiry = nexClaims?.expiry
        if let expiry, expiry <= now { throw NextendoError.invalidResponse }
        if let seconds = object["expires_in"] as? NSNumber {
            let value = seconds.doubleValue
            guard CFGetTypeID(seconds) != CFBooleanGetTypeID(), value > 0, value <= 366 * 24 * 3600 else { throw NextendoError.invalidResponse }
            let serverExpiry = now.addingTimeInterval(value)
            expiry = expiry.map { min($0, serverExpiry) } ?? serverExpiry
        }
        if object["scope"] != nil && !(object["scope"] is String) { throw NextendoError.invalidResponse }
        let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? previousScopes ?? []
        var session = NextendoSession(tokenKind: kind, token: token, identity: identity, scopes: scopes, createdAt: now, expiresAt: expiry)
        if object["refresh_token"] != nil {
            guard kind == .oauth, let clientID, let refresh = object["refresh_token"] as? String, let expiry else { throw NextendoError.invalidResponse }
            let grant = NextendoRenewalGrant(clientID: clientID, accessToken: token, refreshToken: refresh, expiresAt: expiry, scopes: scopes)
            try grant.validate(); session.renewal = grant
        }
        return session
    }
    /// Parses server-issued token metadata for expiry/identity consistency only. HMAC verification belongs to Nextendo.
    static func nexClaims(_ token: String) throws -> (pid: UInt64, username: String, expiry: Date) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "nx2", let payload = Data(nextendoBase64URL: String(parts[1])),
              let signature = Data(nextendoBase64URL: String(parts[2])), signature.count == 32,
              let text = String(data: payload, encoding: .utf8) else { throw NextendoError.invalidResponse }
        let claims = text.split(separator: ".", omittingEmptySubsequences: false)
        guard claims.count >= 3, let first = claims.first, let last = claims.last,
              let pid = UInt64(first), pid > 0, let expiry = Int64(last), expiry > 0 else { throw NextendoError.invalidResponse }
        let username = claims.dropFirst().dropLast().joined(separator: ".")
        guard !username.isEmpty, username.utf8.count <= 128 else { throw NextendoError.invalidResponse }
        return (pid, username, Date(timeIntervalSince1970: Double(expiry)))
    }
    static func decodeUserInfoResponse(_ data: Data) throws -> NextendoIdentity {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NextendoError.invalidResponse }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dictionaries = [object["account"] as? [String: Any], object["identity"] as? [String: Any], object["pid"] == nil ? nil : object].compactMap { $0 }
        let identities = try dictionaries.map { try decoder.decode(NextendoIdentity.self, from: JSONSerialization.data(withJSONObject: $0)) }
        guard let identity = identities.first, let pid = identity.pid, pid > 0,
              let username = identity.username, !username.isEmpty, username.utf8.count <= 128,
              identities.allSatisfy({ $0.pid == pid && $0.username == username }) else { throw NextendoError.invalidResponse }
        return identity
    }
    static func decodeNEXCredentialResponse(_ data: Data, identity: NextendoIdentity, now: Date) throws -> NextendoSession {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["access_token"] == nil, let token = object["nex_token"] as? String else { throw NextendoError.invalidResponse }
        let returned = try decodeUserInfoResponse(data)
        guard identity.pid != nil, identity.pid == returned.pid, identity.username != nil, identity.username == returned.username else { throw NextendoError.invalidResponse }
        let decoder = JSONEncoder(); decoder.keyEncodingStrategy = .convertToSnakeCase
        let account = try JSONSerialization.jsonObject(with: decoder.encode(returned))
        var normalized: [String: Any] = ["nex_token":token, "account":account]
        if let expires = object["expires_in"] { normalized["expires_in"] = expires }
        return try decodeTokenResponse(JSONSerialization.data(withJSONObject: normalized), now: now)
    }
    func encodedForStorage() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }
    static func decodeStored(_ data: Data) throws -> NextendoSession {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard data.count <= 65_536, let session = try? decoder.decode(NextendoSession.self, from: data), session.schemaVersion == 1,
              !session.token.isEmpty, session.token.utf8.count <= 16_384,
              session.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw NextendoError.invalidResponse }
        if session.tokenKind == .nex {
            let claims = try nexClaims(session.token)
            guard session.identity?.pid == claims.pid, session.identity?.username == claims.username,
                  let expiry = session.expiresAt, expiry <= claims.expiry else { throw NextendoError.invalidResponse }
        }
        try session.renewal?.validate()
        return session
    }
}

public struct NextendoAccountSummary: Sendable, Equatable {
    public let tokenKind: NextendoTokenKind
    public let identity: NextendoIdentity?
    public let scopes: [String]
    public let expiresAt: Date?
    public let isExpired: Bool
    public let renewalCheckAt: Date?
    public var hasNEXCredential: Bool { tokenKind == .nex && !isExpired }
}

public protocol NextendoCredentialStore: Sendable {
    func load() throws -> NextendoSession?
    func save(_ session: NextendoSession) throws
    func remove() throws
    func acquireExclusiveLease() async throws -> any NextendoCredentialLease
}

public protocol NextendoCredentialLease: Sendable { func release() }
private struct NextendoNoopLease: NextendoCredentialLease { func release() {} }
extension NextendoCredentialStore {
    // Embedders with process-private stores retain their existing semantics.
    // Shared stores implement a lease covering reload, rotation and commit.
    public func acquireExclusiveLease() async throws -> any NextendoCredentialLease { NextendoNoopLease() }
}

final class NextendoFileCredentialLease: NextendoCredentialLease, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    func release() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    deinit { release() }
    static func acquire(at url: URL,waitTimeout: Duration = .seconds(35)) async throws -> NextendoFileCredentialLease {
        let task = Task.detached {
            try Task.checkCancellation()
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var directory = stat()
            guard lstat(parent.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
                  directory.st_uid == geteuid(), (directory.st_mode & 0o077) == 0 else { throw NextendoError.authorizationUnavailable }
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw NextendoError.authorizationUnavailable }
            let lease = NextendoFileCredentialLease(fd)
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o600, info.st_nlink == 1 else { throw NextendoError.authorizationUnavailable }
            let deadline = ContinuousClock.now.advanced(by: waitTimeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw NextendoError.authorizationUnavailable }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw NextendoError.credentialBusy }
                try await Task.sleep(for: .milliseconds(25))
            }
            return lease
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Shared local-user contract for Studio and native ports. Keychain authorization remains controlled by macOS.
public struct NextendoKeychainStore: NextendoCredentialStore {
    public static let service = "org.nxnative.nextendo.account"
    public static let account = "active"
    public init() {}
    public func acquireExclusiveLease() async throws -> any NextendoCredentialLease {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw NextendoError.authorizationUnavailable }
        // Metadata-only stable inode. Never unlink while another process may
        // hold it; crash/exit closes the descriptor and releases flock.
        return try await NextendoFileCredentialLease.acquire(at: root.appendingPathComponent("NX Port Studio/Nextendo/Locks/account-renewal.lock"))
    }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                      kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false] }
    public func load() throws -> NextendoSession? {
        var values = query; values[kSecReturnData as String] = true; values[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(values as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NextendoError.keychain(status) }
        return try NextendoSession.decodeStored(data)
    }
    public func save(_ session: NextendoSession) throws {
        let data = try session.encodedForStorage()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query; values[kSecValueData as String] = data
            values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(values as CFDictionary, nil)
            guard added == errSecSuccess else { throw NextendoError.keychain(added) }
        } else if status != errSecSuccess { throw NextendoError.keychain(status) }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NextendoError.keychain(status) }
    }
}

public protocol NextendoCallbackReceiver: Sendable {
    func start() async throws -> URL
    func callback() async throws -> URL
    func cancel() async
}

public struct NextendoSignInRequest: Identifiable, Sendable {
    public let id: UUID
    public let authorizationURL: URL
    public let expiresAt: Date
}

public actor NextendoAccountService {
    private struct Pending: Sendable {
        let id: UUID, configuration: NextendoOAuthConfiguration, redirect: URL, verifier: String, state: String, expiresAt: Date
    }
    private enum GameCredentialOperation: Sendable { case signIn(UUID), upgrade(UUID), renewal(UUID) }
    private struct RenewalOutcome: Sendable { let summary: NextendoAccountSummary?; var skippedFreshness = false }
    private let store: any NextendoCredentialStore
    private let http: any NextendoHTTPClient
    private let makeReceiver: @Sendable () throws -> any NextendoCallbackReceiver
    private let now: @Sendable () -> Date
    private var receiver: (any NextendoCallbackReceiver)?
    private var operationID: UUID?
    private var pending: Pending?
    private var gameCredentialRequestID: UUID?
    private var renewalID: UUID?
    private var renewalTask: Task<RenewalOutcome, Error>?
    private var renewalForceRequested = false
    public init(store: any NextendoCredentialStore = NextendoKeychainStore(), http: any NextendoHTTPClient = NextendoURLSessionClient(),
                makeReceiver: @escaping @Sendable () throws -> any NextendoCallbackReceiver = {
                    #if os(macOS)
                    return try NextendoLoopbackServer()
                    #else
                    // Mobile callers supply their system web-authentication receiver.
                    throw NextendoError.invalidConfiguration
                    #endif
                },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.http = http; self.makeReceiver = makeReceiver; self.now = now
    }
    public func currentAccount() throws -> NextendoAccountSummary? { try store.load()?.summary(at: now()) }
    /// Background preparation uses only the account's already granted authority.
    /// One worker is shared by concurrent callers; a cancelled waiter does not
    /// cancel another waiter's refresh. Sign-out/new sign-in invalidates it.
    public func prepareGameAccount(forceGameRefresh: Bool = false) async throws -> NextendoAccountSummary? {
        try Task.checkCancellation()
        if let task = renewalTask, let id = renewalID {
            if forceGameRefresh { renewalForceRequested = true }
            let outcome = try await task.value; try Task.checkCancellation()
            // A fresh-only worker might have finished just before the forced
            // caller arrived. Its completed skip cannot satisfy a fresh mint.
            if forceGameRefresh && outcome.skippedFreshness {
                if renewalID == id { renewalID = nil; renewalTask = nil }
                return try await prepareGameAccount(forceGameRefresh:true)
            }
            return outcome.summary
        }
        guard operationID == nil, gameCredentialRequestID == nil else { throw NextendoError.authorizationUnavailable }
        let id = UUID(); renewalID = id; renewalForceRequested = forceGameRefresh
        let task = Task { try await performRenewal(id) }
        renewalTask = task
        defer { if renewalID == id { renewalID = nil; renewalTask = nil } }
        let outcome = try await task.value; try Task.checkCancellation(); return outcome.summary
    }
    private func checkRenewal(_ id: UUID) throws {
        try Task.checkCancellation()
        guard renewalID == id else { throw CancellationError() }
    }
    private func performRenewal(_ id: UUID) async throws -> RenewalOutcome {
        let lease = try await store.acquireExclusiveLease(); defer { lease.release() }
        try checkRenewal(id)
        // Reload AFTER acquiring the shared-process lease: another port may
        // already have rotated the grant while this process was waiting.
        guard var expected = try store.load() else { return .init(summary:nil) }
        guard let original = expected.renewal else { return .init(summary:expected.summary(at:now())) }
        guard expected.tokenKind == .nex, expected.identity?.pid != nil,
              original.scopes.contains("identity"), original.scopes.contains("game.matchmaking") else { throw NextendoError.authorizationDenied }
        if !renewalForceRequested, let check = expected.summary(at: now()).renewalCheckAt, check > now() { return .init(summary:expected.summary(at:now()),skippedFreshness:true) }
        var oauth = NextendoSession(tokenKind: .oauth, token: original.accessToken, identity: expected.identity,
            scopes: original.scopes, createdAt: now(), expiresAt: original.expiresAt).withRenewal(original)
        if original.expiresAt <= now().addingTimeInterval(60) {
            var request = URLRequest(url: URL(string: "https://nextendo.network/api/oauth/token")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents(); form.queryItems = [.init(name: "grant_type",value: "refresh_token"),
                .init(name: "refresh_token",value: original.refreshToken),.init(name: "client_id",value: original.clientID)]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B").data(using: .utf8)
            let response: NextendoHTTPResponse
            do { response = try await http.send(request) } catch is CancellationError { throw CancellationError() } catch { throw NextendoError.requestFailed }
            try checkRenewal(id)
            guard response.statusCode == 200 else { throw NextendoError.accountHTTPStatus(.refresh,response.statusCode) }
            oauth = try NextendoSession.decodeTokenResponse(response.data,now: now(),clientID: original.clientID,previousScopes: original.scopes)
            guard oauth.tokenKind == .oauth, let rotated = oauth.renewal,
                  rotated.scopes.contains("identity"), rotated.scopes.contains("game.matchmaking"),
                  Set(rotated.scopes).isSubset(of: Set(original.scopes)), try store.load() == expected else { throw NextendoError.invalidResponse }
            // The provider invalidates the old refresh token after its grace
            // interval. Checkpoint only the rotated grant, retaining every old
            // NEX proof/identity/expiry field if later identity/mint work fails.
            // Compare the actual storage representation on the next guard;
            // Date's reference-epoch precision can change on JSON roundtrip.
            expected = try NextendoSession.decodeStored(expected.withRenewal(rotated).encodedForStorage())
            try store.save(expected)
            oauth = NextendoSession(tokenKind: .oauth,token: oauth.token,identity: expected.identity,scopes: oauth.scopes,
                createdAt: oauth.createdAt,expiresAt: oauth.expiresAt).withRenewal(rotated)
        }
        let next = try await gameCredential(using: oauth,operation: .renewal(id))
        try checkRenewal(id)
        guard try store.load() == expected else { throw NextendoError.authorizationUnavailable }
        try store.save(next)
        return .init(summary:next.summary(at:now()))
    }
    /// Uses the current user's scoped OAuth grant. Identity comes from the
    /// service's userinfo endpoint and must match its independently issued NEX proof.
    public func upgradeGameCredential() async throws -> NextendoAccountSummary {
        guard operationID == nil, gameCredentialRequestID == nil, let session = try store.load(), !session.summary(at: now()).isExpired else { throw NextendoError.authorizationUnavailable }
        if session.tokenKind == .nex { return session.summary(at: now()) }
        let id = UUID(); gameCredentialRequestID = id
        defer { if gameCredentialRequestID == id { gameCredentialRequestID = nil } }
        let next = try await gameCredential(using: session, operation: .upgrade(id))
        let lease = try await store.acquireExclusiveLease(); defer { lease.release() }
        try checkGameCredentialOperation(.upgrade(id),session: session)
        guard try store.load() == session else { throw NextendoError.authorizationUnavailable }
        try store.save(next)
        return next.summary(at: now())
    }
    private func checkGameCredentialOperation(_ operation: GameCredentialOperation, session: NextendoSession) throws {
        try Task.checkCancellation()
        switch operation {
        case .signIn(let id): guard operationID == id else { throw CancellationError() }
        case .upgrade(let id): guard gameCredentialRequestID == id else { throw CancellationError() }
        case .renewal(let id): guard renewalID == id else { throw CancellationError() }
        }
        guard !session.summary(at: now()).isExpired else { throw NextendoError.authorizationExpired }
    }
    private func gameCredential(using session: NextendoSession, operation: GameCredentialOperation) async throws -> NextendoSession {
        try checkGameCredentialOperation(operation, session: session)
        guard session.tokenKind == .oauth, session.scopes.contains("identity") else { throw NextendoError.authorizationDenied }
        func get(_ path: String) async throws -> NextendoHTTPResponse {
            var request = URLRequest(url: URL(string: "https://nextendo.network")!.appendingPathComponent(path))
            request.httpMethod = "GET"; request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
            do { return try await http.send(request) } catch is CancellationError { throw CancellationError() } catch { throw NextendoError.requestFailed }
        }
        let userinfo = try await get("api/oauth/userinfo")
        try checkGameCredentialOperation(operation, session: session)
        guard userinfo.statusCode == 200 else { throw NextendoError.accountHTTPStatus(.identity,userinfo.statusCode) }
        let identity = try NextendoSession.decodeUserInfoResponse(userinfo.data)
        if let previous = session.identity?.pid, previous != identity.pid { throw NextendoError.invalidResponse }
        let response = try await get("api/nex-token")
        try checkGameCredentialOperation(operation, session: session)
        guard response.statusCode == 200 else { throw NextendoError.accountHTTPStatus(.gameProof,response.statusCode) }
        let next = try NextendoSession.decodeNEXCredentialResponse(response.data, identity: identity, now: now())
        return try NextendoSession.decodeStored(next.withRenewal(session.renewal).encodedForStorage())
    }
    public func beginSignIn(configuration: NextendoOAuthConfiguration) async throws -> NextendoSignInRequest {
        await cancelSignIn()
        let id = UUID(); operationID = id
        let listener: any NextendoCallbackReceiver
        do { listener = try makeReceiver() } catch { operationID = nil; throw error }
        receiver = listener
        do {
            let redirect = try await listener.start()
            guard operationID == id else { throw CancellationError() }
            guard Self.validRedirect(redirect) else { throw NextendoError.callbackRejected }
            let verifier = try NextendoPKCE.randomString(), state = try NextendoPKCE.randomString()
            let expiry = now().addingTimeInterval(300)
            var url = URLComponents(url: configuration.baseURL.appendingPathComponent("api/oauth/authorize"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: configuration.clientID),
                              .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
                              .init(name: "state", value: state), .init(name: "code_challenge", value: try NextendoPKCE.challenge(for: verifier)), .init(name: "code_challenge_method", value: "S256")]
            pending = Pending(id: id, configuration: configuration, redirect: redirect, verifier: verifier, state: state, expiresAt: expiry)
            return NextendoSignInRequest(id: id, authorizationURL: url.url!, expiresAt: expiry)
        } catch {
            if operationID == id { operationID = nil; pending = nil; receiver = nil }
            await listener.cancel(); throw error
        }
    }
    /// Game callers keep OAuth transient and replace active storage only after
    /// the provider issues a coherent NEX proof. An unsupported grant stays an error.
    public func finishSignIn(_ id: UUID, forGames: Bool = false) async throws -> NextendoAccountSummary {
        guard let attempt = pending, attempt.id == id, operationID == id, let listener = receiver else { throw NextendoError.authorizationUnavailable }
        pending = nil // consume once, before the first suspension (including invalid callbacks)
        do {
            let previous = forGames ? try store.load() : nil
            guard attempt.expiresAt > now() else { throw NextendoError.authorizationExpired }
            let callback = try await withTaskCancellationHandler { try await listener.callback() } onCancel: { Task { await listener.cancel() } }
            try Task.checkCancellation()
            guard operationID == id else { throw CancellationError() }
            guard attempt.expiresAt > now() else { throw NextendoError.authorizationExpired }
            let code = try Self.authorizationCode(callback: callback, redirect: attempt.redirect, expectedState: attempt.state)
            var request = URLRequest(url: attempt.configuration.baseURL.appendingPathComponent("api/oauth/token"))
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(attempt.configuration.clientID, forHTTPHeaderField: "X-Nextendo-Client-Id")
            var fields = URLComponents()
            fields.queryItems = [.init(name: "grant_type", value: "authorization_code"), .init(name: "client_id", value: attempt.configuration.clientID),
                                 .init(name: "code", value: code), .init(name: "redirect_uri", value: attempt.redirect.absoluteString), .init(name: "code_verifier", value: attempt.verifier)]
            request.httpBody = fields.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            let response: NextendoHTTPResponse
            do { response = try await http.send(request) } catch is CancellationError { throw CancellationError() } catch { throw NextendoError.requestFailed }
            try Task.checkCancellation()
            guard operationID == id else { throw CancellationError() }
            guard response.statusCode == 200 else { throw forGames ? NextendoError.accountHTTPStatus(.codeExchange,response.statusCode) : NextendoError.httpStatus(response.statusCode) }
            var session = try NextendoSession.decodeTokenResponse(response.data, now: now(),clientID: attempt.configuration.clientID,
                previousScopes: attempt.configuration.scopes)
            if session.tokenKind == .oauth && !Set(session.scopes).isSubset(of:Set(attempt.configuration.scopes)) { throw NextendoError.invalidResponse }
            if forGames {
                if session.tokenKind == .oauth { session = try await gameCredential(using: session, operation: .signIn(id)) }
                session = try NextendoSession.decodeStored(session.encodedForStorage())
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                guard !session.summary(at: now()).isExpired else { throw NextendoError.authorizationExpired }
            }
            let lease = try await store.acquireExclusiveLease(); defer { lease.release() }
            try Task.checkCancellation()
            guard operationID == id else { throw CancellationError() }
            if forGames { guard try store.load() == previous else { throw NextendoError.authorizationUnavailable } }
            try store.save(session)
            operationID = nil; receiver = nil; await listener.cancel()
            return session.summary(at: now())
        } catch {
            if operationID == id { operationID = nil; receiver = nil }
            await listener.cancel(); throw error
        }
    }
    public func cancelSignIn() async {
        renewalID = nil; renewalTask?.cancel(); renewalTask = nil
        let old = receiver; operationID = nil; pending = nil; receiver = nil; gameCredentialRequestID = nil
        await old?.cancel()
    }
    public func signOut() async throws {
        await cancelSignIn()
        let lease = try await store.acquireExclusiveLease(); defer { lease.release() }
        try store.remove()
    }

    static func validRedirect(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return false }
        if url.absoluteString == "nxnative-nextendo://callback" { return true }
        return c.scheme == "http" && c.host == "127.0.0.1" && c.percentEncodedHost == "127.0.0.1" &&
            (1...65535).contains(c.port ?? 0) && c.percentEncodedPath == "/callback"
    }
    static func authorizationCode(callback: URL, redirect: URL, expectedState: String) throws -> String {
        guard validRedirect(redirect), let c = URLComponents(url: callback, resolvingAgainstBaseURL: false), c.scheme == redirect.scheme,
              c.host == redirect.host, c.port == redirect.port, c.path == redirect.path, c.fragment == nil, c.user == nil, c.password == nil else { throw NextendoError.callbackRejected }
        var endpoint = c; endpoint.query = nil
        guard endpoint.url?.absoluteString == redirect.absoluteString else { throw NextendoError.callbackRejected }
        let items = c.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else { throw NextendoError.callbackRejected }
            values[item.name] = value
        }
        let expected = Array(expectedState.utf8), actual = Array((values["state"] ?? "").utf8)
        guard !expected.isEmpty, expected.count == actual.count,
              expected.withUnsafeBytes({ lhs in actual.withUnsafeBytes { rhs in timingsafe_bcmp(lhs.baseAddress!, rhs.baseAddress!, expected.count) } }) == 0 else { throw NextendoError.callbackRejected }
        if values["error"] != nil {
            guard values["code"] == nil else { throw NextendoError.callbackRejected }
            throw NextendoError.authorizationDenied
        }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 4096, !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NextendoError.callbackRejected }
        return code
    }
}
