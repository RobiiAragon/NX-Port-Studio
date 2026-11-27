// The agent's hub (docs/nextendo-agent.md, phase 3): while no game runs, it keeps
// polling the account so Studio can show friends and the Mac can notify. Nextendo has
// no push channel, so everything here is a bounded poll.
import Foundation

/// One entry of `GET /api/friends`: only what Studio and notifications show.
public struct NextendoFriend: Sendable, Equatable, Identifiable {
    public let pid: UInt64
    public let name: String
    /// nn::friends PresenceStatus: 0 offline, 1 online, 2 playing.
    public let status: Int
    public let titleID: String?
    /// The friend's profile picture from the provider's gallery (`avatar`, served at
    /// `/avatars/<id>.jpg`) and its background colour (`color`, `#rrggbb`); nil when unset.
    public let avatar: String?
    public let color: String?
    /// A best friend (`favorite`): shown first, as the provider's own apps do.
    public let favorite: Bool
    public let friendCode: String?
    public var id: UInt64 { pid }
    public var isOnline: Bool { status > 0 }
    public var avatarURL: URL? { avatar.flatMap { URL(string: "https://nextendo.network/avatars/\($0).jpg") } }
    public init(pid: UInt64, name: String, status: Int, titleID: String?,
                avatar: String? = nil, color: String? = nil, favorite: Bool = false, friendCode: String? = nil) {
        self.pid = pid; self.name = name; self.status = status; self.titleID = titleID
        self.avatar = avatar; self.color = color; self.favorite = favorite; self.friendCode = friendCode
    }
}

/// A friend code as the provider stores it (`SW-0000-0000-0000`), from any spelling with
/// its twelve digits; nil for anything else.
public enum NextendoFriendCode {
    public static func normalized(_ text: String) -> String? {
        let digits = text.filter(\.isASCII).filter(\.isNumber)
        guard digits.count == 12, text.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " || $0.uppercased() == "S" || $0.uppercased() == "W" }) else { return nil }
        let d = Array(digits)
        return "SW-" + String(d[0..<4]) + "-" + String(d[4..<8]) + "-" + String(d[8..<12])
    }
}

public struct NextendoFriendsView: Sendable, Equatable {
    public let friends: [NextendoFriend]
    /// Incoming friend requests.
    public let requests: [NextendoFriend]
    /// Requests this account sent that are still pending.
    public let sent: [NextendoFriend]
    public init(friends: [NextendoFriend], requests: [NextendoFriend], sent: [NextendoFriend] = []) {
        self.friends = friends; self.requests = requests; self.sent = sent
    }

    /// `{friends, requests, sent}`; a malformed entry is skipped, a malformed document is nil.
    public static func decode(_ data: Data) -> NextendoFriendsView? {
        guard data.count <= NextendoAgent.responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["friends"] as? [Any] else { return nil }
        func entry(_ value: Any) -> NextendoFriend? {
            guard let row = value as? [String: Any], let number = row["pid"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.uint64Value > 0 else { return nil }
            let text = [row["name"], row["username"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? String(number.uint64Value)
            let presence = row["presence"] as? [String: Any]
            let status = (presence?["status"] as? NSNumber).map { min(max($0.intValue, 0), 2) } ?? 0
            let title = (presence?["app_id"] as? String).flatMap { $0.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) == nil ? nil : $0.lowercased() }
            func matching(_ key: String, _ pattern: String) -> String? {
                (row[key] as? String).flatMap { $0.range(of: pattern, options: .regularExpression) == nil ? nil : $0 }
            }
            return NextendoFriend(pid: number.uint64Value, name: String(text.prefix(64)), status: status, titleID: title,
                                  avatar: matching("avatar", "^[A-Za-z0-9_-]{1,64}$"), color: matching("color", "^#[0-9A-Fa-f]{6}$"),
                                  favorite: row["favorite"] as? Bool == true, friendCode: matching("friend_code", "^SW-[0-9]{4}-[0-9]{4}-[0-9]{4}$"))
        }
        return NextendoFriendsView(friends: rows.prefix(1024).compactMap(entry),
                                   requests: ((root["requests"] as? [Any]) ?? []).prefix(1024).compactMap(entry),
                                   sent: ((root["sent"] as? [Any]) ?? []).prefix(1024).compactMap(entry))
    }
}

public enum NextendoHubEvent: Sendable, Equatable {
    /// A friend came online; `game` is the name of an installed port for their title, if any.
    case online(NextendoFriend, game: String?)
    case request(NextendoFriend)
    case revoked
}

public protocol NextendoHubNotifying: Sendable {
    /// Asks macOS for permission to notify; false when the user declined.
    func authorize() async -> Bool
    func post(_ event: NextendoHubEvent) async
}

public protocol NextendoHubSettings: Sendable {
    var notifications: Bool { get nonmutating set }
}

/// The agent's own preferences (its bundle's defaults domain).
public struct NextendoHubDefaults: NextendoHubSettings {
    private static let key = "NotifyFriends"
    public init() {}
    public var notifications: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }
}

public final class NextendoHubMemorySettings: NextendoHubSettings, @unchecked Sendable {
    private let lock = NSLock(); private var value: Bool
    public init(notifications: Bool = false) { value = notifications }
    public var notifications: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Names of the Mac ports installed for each title, for "X is playing Y".
public enum NextendoInstalledGames {
    public static func names(in folders: [URL] = InstalledMacPorts.defaultFolders) -> [String: String] {
        var names: [String: String] = [:]
        for port in InstalledMacPorts.scan(in: folders) where port.isPrimaryHost { names[port.titleID.lowercased()] = port.name }
        return names
    }
}

public actor NextendoAgentHub {
    private let account: NextendoAgentAccount
    private let notifier: any NextendoHubNotifying
    private let settings: any NextendoHubSettings
    private let connectedPorts: @Sendable () -> Int
    private let games: @Sendable () -> [String: String]
    /// One friends poll a minute; the provider's presence lasts 90 s.
    public static let interval: Duration = .seconds(60)
    /// After a 429 or a failure, skip this many polls.
    private var pause = 0
    private var baseline: (generation: UInt64, online: Set<UInt64>, requests: Set<UInt64>)?
    private var revoked: Bool?
    public private(set) var latest: NextendoFriendsView?

    public init(account: NextendoAgentAccount, notifier: any NextendoHubNotifying, settings: any NextendoHubSettings,
                connectedPorts: @escaping @Sendable () -> Int, games: @escaping @Sendable () -> [String: String] = { NextendoInstalledGames.names() }) {
        self.account = account; self.notifier = notifier; self.settings = settings
        self.connectedPorts = connectedPorts; self.games = games
    }

    public var notificationsEnabled: Bool { settings.notifications }

    /// Studio's switch. Turning it on asks macOS once; a refusal leaves it off.
    public func setNotifications(_ enabled: Bool) async -> Bool {
        let granted = enabled ? await notifier.authorize() : false
        settings.notifications = granted
        return granted
    }

    public func run() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// One cycle: the friends snapshot and its changes, then, while a game is open,
    /// whether the website closed this Mac's session.
    public func poll() async {
        if pause > 0 { pause -= 1; return }
        let reply = await account.social("friends", body: nil, port: 0)
        let generation = await account.generation
        if reply.status == .ok, (200..<300).contains(reply.http), let body = reply.body, let view = NextendoFriendsView.decode(body) {
            latest = view
            await report(view, generation: generation)
        } else {
            if reply.http == 429 { pause = 4 } else if reply.status == .failed || reply.http >= 500 { pause = 1 }
            if reply.status == .signedOut { latest = nil; baseline = nil; revoked = nil }
        }
        guard connectedPorts() > 0 else { revoked = nil; return }
        let status = await account.sessionRevoked()
        guard status.status == .ok, let now = status.revoked else { return }
        // Only a change seen here counts: a session closed long ago stays listed as revoked.
        if now, revoked == false {
            await account.signOutRevoked()
            latest = nil; baseline = nil
            if settings.notifications { await notifier.post(.revoked) }
        }
        revoked = now
    }

    /// The snapshot Studio shows, fetched now when the hub has none yet.
    public func friends() async -> (status: NextendoAgentStatus, view: NextendoFriendsView?) {
        let reply = await account.social("friends", body: nil, port: 0)
        guard reply.status == .ok else { return (reply.status, nil) }
        guard (200..<300).contains(reply.http), let body = reply.body, let view = NextendoFriendsView.decode(body) else { return (.failed, nil) }
        latest = view
        return (.ok, view)
    }

    private func report(_ view: NextendoFriendsView, generation: UInt64) async {
        let online = Set(view.friends.filter(\.isOnline).map(\.pid)), requests = Set(view.requests.map(\.pid))
        defer { baseline = (generation, online, requests) }
        // The first snapshot of an account only sets what is already true.
        guard let previous = baseline, previous.generation == generation, settings.notifications else { return }
        let names = view.friends.contains { $0.isOnline && !previous.online.contains($0.pid) } ? games() : [:]
        for friend in view.friends where friend.isOnline && !previous.online.contains(friend.pid) {
            await notifier.post(.online(friend, game: friend.titleID.flatMap { names[$0] }))
        }
        for friend in view.requests where !previous.requests.contains(friend.pid) { await notifier.post(.request(friend)) }
    }
}

/// The few lines the agent shows outside Studio, in Studio's languages.
public enum NextendoHubText {
    public static func text(_ event: NextendoHubEvent, languages: [String] = Locale.preferredLanguages) -> (title: String, body: String) {
        let language = languages.lazy.compactMap { code -> String? in
            let lower = code.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            return ["en", "es", "fr", "ja"].first { lower.hasPrefix($0) }
        }.first ?? "en"
        let table = strings[language] ?? strings["en"]!
        switch event {
        case .online(let friend, let game?): return (friend.name, String(format: table[1], game))
        case .online(let friend, nil): return (friend.name, table[0])
        case .request(let friend): return (friend.name, table[2])
        case .revoked: return (table[3], table[4])
        }
    }
    private static let strings: [String: [String]] = [
        "en": ["Is online.", "Is playing %@.", "Sent you a friend request.", "Nextendo signed this Mac out",
               "This Mac's game session was closed on nextendo.network. Sign in again in NX Port Studio to play online."],
        "es": ["Está en línea.", "Está jugando a %@.", "Te envió una solicitud de amistad.", "Nextendo cerró la sesión en este Mac",
               "La sesión de juego de este Mac se cerró en nextendo.network. Vuelve a iniciar sesión en NX Port Studio para jugar en línea."],
        "fr": ["Est en ligne.", "Joue à %@.", "T'a envoyé une demande d'ami.", "Nextendo a déconnecté ce Mac",
               "La session de jeu de ce Mac a été fermée sur nextendo.network. Reconnecte-toi dans NX Port Studio pour jouer en ligne."],
        "ja": ["オンラインです。", "%@ をプレイ中です。", "フレンド申請が届きました。", "Nextendo がこの Mac をサインアウトしました",
               "この Mac のゲームセッションは nextendo.network で終了されました。オンラインで遊ぶには NX Port Studio で再度サインインしてください。"],
        "zh-Hans": ["在线。", "正在玩 %@。", "向你发送了好友请求。", "Nextendo 已将此 Mac 退出登录",
                    "此 Mac 的游戏会话已在 nextendo.network 上关闭。请在 NX Port Studio 中重新登录以进行在线游戏。"],
    ]
}
