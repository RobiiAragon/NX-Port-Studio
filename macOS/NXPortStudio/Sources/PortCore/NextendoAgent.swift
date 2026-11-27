// The Mac Nextendo agent's XPC contract (docs/nextendo-agent.md), shared by Studio,
// the agent and every Mac port (dm/mac/pack_app.py compiles this file into the
// port's bootstrap). Foundation only: no process, Keychain or UI code here.
import Foundation

public enum NextendoAgent {
    /// Ports connect here; each connection must match a cdhash Studio registered.
    public static let portService = "org.nxnative.portstudio.agent"
    /// Studio only: the exact app bundle that contains the agent.
    public static let adminService = "org.nxnative.portstudio.agent.admin"
    public static let launchAgentPlist = "org.nxnative.portstudio.agent.plist"
    /// The agent is a small app inside Studio, so it has a bundle of its own for notifications.
    public static let bundlePath = "Contents/Library/LoginItems/NX Port Studio Agent.app"
    /// 2 adds `social`. A port built for 1 gets `versionMismatch` and keeps its own
    /// path, which still holds the OAuth grant a version-1 record lacked.
    public static let protocolVersion = 2
    /// The host's credential provider buffer (dm/host/hle_nextendo_apple.m).
    public static let credentialLimit = 65_536
    /// The host's account API buffer and presence body bounds (dm/host/hle_nextendo_api_apple.m).
    public static let responseLimit = 1 << 20
    public static let presenceLimit = 4096
    /// The account API resources a port may ask for, and the OAuth scope each needs.
    public static let socialScopes = ["me": "identity", "friends": "friends", "presence": "presence"]
    /// Peer allowlist bound; the oldest registrations are dropped first.
    public static let peerLimit = 512
}

/// Raw values cross XPC as Int. Unknown values read as `.failed`.
public enum NextendoAgentStatus: Int, Sendable {
    case ok = 0, signedOut = 1, unavailable = 2, versionMismatch = 3, refused = 4, failed = 5
    public init(wire: Int) { self = NextendoAgentStatus(rawValue: wire) ?? .failed }
}

/// Exported by each port connection; the agent calls it after Studio reports an account change.
@objc public protocol NextendoAgentListener {
    func accountChanged(_ generation: UInt64)
}

@objc public protocol NextendoAgentPortService {
    /// Reply: status, agent protocol version.
    func hello(_ version: Int, titleID: String, gameVersion: String, reply: @escaping @Sendable (Int, Int) -> Void)
    /// Reply: status, schema-1 record without its renewal grant, account generation.
    /// `renew` runs the same coalesced game-account preparation a port runs today at boot.
    func gameCredential(renew: Bool, reply: @escaping @Sendable (Int, Data?, UInt64) -> Void)
    /// One account API request made with the agent's own OAuth grant, so the port holds
    /// no bearer. `resource` is me, friends or presence; only presence has a JSON body.
    /// Reply: status, HTTP status (0 when nothing was sent), response body on 2xx.
    func social(_ resource: String, body: Data?, reply: @escaping @Sendable (Int, Int, Data?) -> Void)
}

@objc public protocol NextendoAgentAdminService {
    /// Reply: status. The cdhash is the 20-byte SHA-1 prefix form `codesign` reports.
    func registerPeer(_ cdhash: Data, reply: @escaping @Sendable (Int) -> Void)
    /// Studio changed the stored account (sign-in, sign-out, new credential). Reply: new generation.
    func accountDidChange(reply: @escaping @Sendable (UInt64) -> Void)
    /// Reply: protocol version, registered peers, connected ports.
    func status(reply: @escaping @Sendable (Int, Int, Int) -> Void)
    /// Reply: status, the account's `GET /api/friends` body (images omitted).
    func friends(reply: @escaping @Sendable (Int, Data?) -> Void)
    /// Accepts or declines an incoming request. Reply: status, HTTP status.
    func answerFriendRequest(_ pid: UInt64, accept: Bool, reply: @escaping @Sendable (Int, Int) -> Void)
    /// Turns the agent's notifications on or off. Reply: whether they are on now
    /// (false when macOS refused permission).
    func setNotifications(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Reply: whether the agent's notifications are on.
    func notifications(reply: @escaping @Sendable (Bool) -> Void)
}

public enum NextendoAgentInterfaces {
    public static func port() -> NSXPCInterface { NSXPCInterface(with: NextendoAgentPortService.self) }
    public static func admin() -> NSXPCInterface { NSXPCInterface(with: NextendoAgentAdminService.self) }
    public static func listener() -> NSXPCInterface { NSXPCInterface(with: NextendoAgentListener.self) }
}

extension NextendoSession {
    /// What a port receives: the stored schema-1 record without the renewal grant,
    /// so no refresh token leaves the agent. The host decoder treats `renewal` as optional.
    public func encodedForPort() throws -> Data { try withRenewal(nil).encodedForStorage() }

    /// A port accepts only an unexpired NEX record that carries no renewal grant.
    public static func decodeForPort(_ data: Data, now: Date = Date()) throws -> NextendoSession {
        guard data.count <= NextendoAgent.credentialLimit else { throw NextendoError.invalidResponse }
        let session = try decodeStored(data)
        guard session.tokenKind == .nex, session.renewal == nil, !session.summary(at: now).isExpired else { throw NextendoError.invalidResponse }
        return session
    }
}
