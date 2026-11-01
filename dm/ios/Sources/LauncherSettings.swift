// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine
import Darwin

enum LauncherNetworkMode: String, CaseIterable, Identifiable {
    case automatic = "auto", offline, lan, ldn, nextendo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic connection"
        case .offline: "Offline"
        case .lan: "LAN"
        case .ldn: "Local wireless bridge (LDN)"
        case .nextendo: "Nextendo"
        }
    }
    var usesLocalDiscovery: Bool { self == .automatic || self == .lan || self == .ldn }
    var supportsNextendo: Bool { self == .automatic || self == .nextendo }
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
        if routesStatus == 1 { return "Game services still need a verified connection profile. Open Nextendo setup on this iPhone." }
        if routesStatus != 0 { return "The game service profile could not be validated. Open Nextendo setup for details." }
        if !hasValidCredential { return "Link or renew your Nextendo game credential in this iPhone’s Nextendo setup." }
        return nil
    }
}

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let unavailable: String?   // capability gate; defaults cannot be bypassed by saved choices or an env file
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        if unavailable != nil && !isDefault(v) { return false }
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case unavailable, env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off }
}
struct SettingsFile: Decodable { let settings: [Setting] }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let maximumFramesPerSecond: Int
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    var fromFile: Set<String> { fixed }   // compatibility: all fixed launch/file overrides
    @Published var values: [String: String] = [:]
    @Published var networkMode: LauncherNetworkMode = .automatic
    @Published var discoveryPeer = ""
    @Published var nextendoStatus: LauncherNextendoStatus?
    @Published var uiLanguage: LauncherUILanguage = .spanish {
        didSet { defaults.set(uiLanguage.rawValue, forKey: "launcher.uiLanguage") }
    }

    private let defaults: UserDefaults

    init(_ settings: [Setting], defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         maximumFramesPerSecond: Int = 0) {
        self.defaults = defaults
        self.settings = settings
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.uiLanguage = defaults.string(forKey: "launcher.uiLanguage").flatMap(LauncherUILanguage.init(rawValue:)) ?? .spanish
        // Old launchers persisted mutually exclusive protocols. They now share
        // the guest's menu; an explicitly saved offline choice stays offline.
        if defaults.integer(forKey: "launcher.networkSelectionVersion") < 2 {
            if let saved = defaults.string(forKey: "launcher.DM_NETWORK"), ["lan", "ldn", "nextendo"].contains(saved) {
                defaults.removeObject(forKey: "launcher.DM_NETWORK")
            }
            defaults.set(2, forKey: "launcher.networkSelectionVersion")
        }
        // The previous launcher required an address. That forced value was not
        // an explicit choice to override automatic discovery. Migrate once.
        if defaults.string(forKey: "launcher.discoveryStyle") == nil {
            defaults.removeObject(forKey: "launcher.DM_NET_DISCOVERY_PEER")
            defaults.set("automatic", forKey: "launcher.discoveryStyle")
        }
        let env = environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        for s in settings {
            if s.unavailable != nil { values[s.env] = s.def; continue }
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
        let mode = fromFile.contains("DM_NETWORK") ? environment["DM_NETWORK"] : (ignoreSaved ? nil : defaults.string(forKey: "launcher.DM_NETWORK"))
        networkMode = mode.flatMap(LauncherNetworkMode.init(rawValue:)) ?? (fromFile.contains("DM_NETWORK") ? .offline : .automatic)
        discoveryPeer = (fromFile.contains("DM_NET_DISCOVERY_PEER") ? environment["DM_NET_DISCOVERY_PEER"] : (ignoreSaved ? nil : defaults.string(forKey: "launcher.DM_NET_DISCOVERY_PEER"))) ?? ""
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var changed: Bool {
        settings.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } ||
        (!fromFile.contains("DM_NETWORK") && networkMode != .automatic) ||
        (!fromFile.contains("DM_NET_DISCOVERY_PEER") && !discoveryPeer.isEmpty)
    }
    var networkValidationError: String? {
        guard networkMode.usesLocalDiscovery, !discoveryPeer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LauncherNetwork.peer(discoveryPeer) == nil ? "Enter a valid unicast IPv4 address, without a port." : nil
    }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset() {
        nextendoStatus = nil
        for s in settings where s.unavailable != nil || !fixed.contains(s.env) { values[s.env] = s.def }
        if !fixed.contains("DM_NETWORK") { networkMode = .automatic }
        if !fixed.contains("DM_NET_DISCOVERY_PEER") { discoveryPeer = "" }
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    @discardableResult func apply() -> Bool {
        guard networkValidationError == nil else { return false }
        for s in settings {
            if s.unavailable != nil {
                values[s.env] = s.def
                if !ignoreSaved { defaults.removeObject(forKey: "launcher." + s.env) }
                setenv(s.env, s.def, 1)
                continue
            }
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
        if !fromFile.contains("DM_NETWORK") {
            if !ignoreSaved {
                if networkMode == .automatic { defaults.removeObject(forKey: "launcher.DM_NETWORK") }
                else { defaults.set(networkMode.rawValue, forKey: "launcher.DM_NETWORK") }
            }
            setenv("DM_NETWORK", networkMode.rawValue, 1)
        }
        if !fromFile.contains("DM_NET_DISCOVERY_PEER") {
            if let peer = LauncherNetwork.peer(discoveryPeer) {
                if !ignoreSaved { defaults.set(peer, forKey: "launcher.DM_NET_DISCOVERY_PEER"); defaults.set("manual", forKey: "launcher.discoveryStyle") }
                setenv("DM_NET_DISCOVERY_PEER", peer, 1)
            } else {
                if !ignoreSaved { defaults.removeObject(forKey: "launcher.DM_NET_DISCOVERY_PEER"); defaults.set("automatic", forKey: "launcher.discoveryStyle") }
                unsetenv("DM_NET_DISCOVERY_PEER")
            }
        }
        fputs("launcher: network mode \(networkMode.rawValue) (unicast discovery)\n", stderr)
        return true
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        if !fixed.contains("DM_NETWORK") && networkMode != .automatic { setenv("DM_NETWORK", networkMode.rawValue, 1) }
        if !fixed.contains("DM_NET_DISCOVERY_PEER"), let peer = LauncherNetwork.peer(discoveryPeer) { setenv("DM_NET_DISCOVERY_PEER", peer, 1) }
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if !s.isDefault(v) { setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (saved choice)\n", stderr) }
        }
    }
}
