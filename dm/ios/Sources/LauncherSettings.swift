// Launcher settings, validation and persistence. Shared by the iOS UI and the native storage regression test.
import Foundation
import Combine
import Darwin

enum LauncherNetworkMode: String, CaseIterable, Identifiable {
    case offline, lan, ldn, nextendo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .offline: "Offline"
        case .lan: "LAN"
        case .ldn: "Local wireless bridge (LDN)"
        case .nextendo: "Nextendo"
        }
    }
    var usesLocalDiscovery: Bool { self == .lan || self == .ldn }
}

enum LauncherNetwork {
    // Match the native IPv4 unicast boundary. No DNS, URL, port or broadcast
    // capability is inferred from a text field or a saved preference.
    static func peer(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        let host = UInt32(bigEndian: address.s_addr)
        guard host != 0, host < 0xe0000000 else { return nil }
        return "\(host >> 24).\((host >> 16) & 255).\((host >> 8) & 255).\(host & 255)"
    }
}

struct LauncherNextendoStatus: Equatable {
    let routesStatus: Int
    let hasValidCredential: Bool
    init(rawValue: UInt32) {
        routesStatus = Int(rawValue & 255)
        hasValidCredential = rawValue & (1 << 8) != 0
    }
    var canStart: Bool { routesStatus == 0 && hasValidCredential }
    var blockingMessage: String? {
        if routesStatus == 1 { return "Compatible services are not configured. You can play using Offline or LAN." }
        if routesStatus != 0 { return "The Nextendo service configuration could not be validated. You can play using Offline or LAN." }
        if !hasValidCredential { return "No valid Nextendo game credential is available on this iPhone. Link or renew it in NX Port Studio. You can play using Offline or LAN." }
        return nil
    }
}

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, options, min, max, step, on, off }
}
struct SettingsFile: Decodable { let settings: [Setting] }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fromFile: Set<String>   // set by an env file: shown, not changed
    @Published var values: [String: String] = [:]
    @Published var networkMode: LauncherNetworkMode = .offline
    @Published var discoveryPeer = ""
    @Published var nextendoStatus: LauncherNextendoStatus?

    private let defaults: UserDefaults

    init(_ settings: [Setting], defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.settings = settings
        // The previous launcher required an address. That forced value was not
        // an explicit choice to override automatic discovery. Migrate once.
        if defaults.string(forKey: "launcher.discoveryStyle") == nil {
            defaults.removeObject(forKey: "launcher.DM_NET_DISCOVERY_PEER")
            defaults.set("automatic", forKey: "launcher.discoveryStyle")
        }
        fromFile = Set((environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for s in settings {
            if fromFile.contains(s.env), let v = environment[s.env] { values[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
        let mode = fromFile.contains("DM_NETWORK") ? environment["DM_NETWORK"] : defaults.string(forKey: "launcher.DM_NETWORK")
        networkMode = mode.flatMap(LauncherNetworkMode.init(rawValue:)) ?? .offline
        discoveryPeer = (fromFile.contains("DM_NET_DISCOVERY_PEER") ? environment["DM_NET_DISCOVERY_PEER"] : defaults.string(forKey: "launcher.DM_NET_DISCOVERY_PEER")) ?? ""
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    var changed: Bool {
        settings.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } ||
        (!fromFile.contains("DM_NETWORK") && networkMode != .offline) ||
        (!fromFile.contains("DM_NET_DISCOVERY_PEER") && !discoveryPeer.isEmpty)
    }
    var networkValidationError: String? {
        guard networkMode.usesLocalDiscovery, !discoveryPeer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LauncherNetwork.peer(discoveryPeer) == nil ? "Enter a valid unicast IPv4 address, without a port." : nil
    }

    // Reset every launcher choice to the game's defaults; an env file's values stay.
    func reset() {
        nextendoStatus = nil
        for s in settings {
            defaults.removeObject(forKey: "launcher." + s.env)
            if !fromFile.contains(s.env) { values[s.env] = s.def }
        }
        defaults.removeObject(forKey: "launcher.DM_NETWORK")
        defaults.removeObject(forKey: "launcher.DM_NET_DISCOVERY_PEER")
        defaults.set("automatic", forKey: "launcher.discoveryStyle")
        if !fromFile.contains("DM_NETWORK") { networkMode = .offline }
        if !fromFile.contains("DM_NET_DISCOVERY_PEER") { discoveryPeer = "" }
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    @discardableResult func apply() -> Bool {
        guard networkValidationError == nil else { return false }
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
        if !fromFile.contains("DM_NETWORK") {
            if networkMode == .offline { defaults.removeObject(forKey: "launcher.DM_NETWORK") }
            else { defaults.set(networkMode.rawValue, forKey: "launcher.DM_NETWORK") }
            setenv("DM_NETWORK", networkMode.rawValue, 1)
        }
        if !fromFile.contains("DM_NET_DISCOVERY_PEER") {
            if let peer = LauncherNetwork.peer(discoveryPeer) {
                defaults.set(peer, forKey: "launcher.DM_NET_DISCOVERY_PEER")
                defaults.set("manual", forKey: "launcher.discoveryStyle")
                setenv("DM_NET_DISCOVERY_PEER", peer, 1)
            } else {
                defaults.removeObject(forKey: "launcher.DM_NET_DISCOVERY_PEER")
                defaults.set("automatic", forKey: "launcher.discoveryStyle")
                unsetenv("DM_NET_DISCOVERY_PEER")
            }
        }
        fputs("launcher: network mode \(networkMode.rawValue) (unicast discovery)\n", stderr)
        return true
    }
}
