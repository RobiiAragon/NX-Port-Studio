import AppKit
import PortCore
import ServiceManagement

/// Studio's control of its launchd agent (docs/nextendo-agent.md): register or
/// remove it, register each installed Mac port's code, and report account changes.
enum NextendoAgentState: Equatable, Sendable {
    /// Only the packaged app carries the agent and its launchd plist.
    case unavailable
    case off, needsApproval, on
}

extension StudioModel {
    private var nextendoAgentService: SMAppService { SMAppService.agent(plistName: NextendoAgent.launchAgentPlist) }

    /// Whether this bundle carries the agent: the packaged app does, `swift run` does not.
    private var bundleCarriesNextendoAgent: Bool {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        return FileManager.default.fileExists(atPath: contents.appendingPathComponent("Library/LaunchAgents/\(NextendoAgent.launchAgentPlist)").path)
            && FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent(NextendoAgent.bundlePath).path)
    }

    func refreshNextendoAgentState() {
        guard bundleCarriesNextendoAgent else { nextendoAgentState = .unavailable; return }
        // SMAppService reports .notFound, not .notRegistered, for an agent that was
        // never registered, so with the plist in the bundle both mean "off".
        nextendoAgentState = switch nextendoAgentService.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    private static let registeredAgentKey = "NextendoAgentRegisteredCDHash"
    private var bundledAgentCDHash: String? {
        (try? NextendoAgentCode.cdhash(of: Bundle.main.bundleURL.appendingPathComponent(NextendoAgent.bundlePath))).map(NextendoAgentCode.hex)
    }

    /// launchd keeps a launch constraint on the code that was registered, so after
    /// Studio is updated the new agent is refused to start (exit 78) until it is
    /// registered again. Studio remembers which agent it registered and renews it.
    func renewNextendoAgentIfUpdated() async {
        refreshNextendoAgentState()
        guard nextendoAgentState == .on, !isChangingNextendoAgent, let current = bundledAgentCDHash,
              UserDefaults.standard.string(forKey: Self.registeredAgentKey) != current else { return }
        isChangingNextendoAgent = true
        defer { isChangingNextendoAgent = false; refreshNextendoAgentState() }
        do {
            // Workaround (docs/nextendo-agent.md, open): registering right after the
            // removal sometimes keeps the old constraint, and launchd refuses the new
            // agent. Unknown why; a second removal after a pause has always cleared it.
            for attempt in 0..<3 {
                try? await nextendoAgentService.unregister()
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                try nextendoAgentService.register()
                if await nextendoAgentAnswers() { break }
            }
            UserDefaults.standard.set(current, forKey: Self.registeredAgentKey)
            appendLog("Registered the updated Nextendo agent with macOS.")
            refreshNextendoAgentState()
            if nextendoAgentState == .on { await registerInstalledPortsWithNextendoAgent() }
        } catch {
            nextendoAgentMessage = t("macOS did not change the background agent. Try again, or check Login Items in System Settings.")
        }
    }

    /// Whether the registered agent started and answers, within a few seconds.
    private func nextendoAgentAnswers() async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if await nextendoAgentClient.status() != nil { return true }
        }
        return false
    }

    func setNextendoAgent(enabled: Bool) async {
        guard !isChangingNextendoAgent, nextendoAgentState != .unavailable else { return }
        isChangingNextendoAgent = true; nextendoAgentMessage = nil
        defer { isChangingNextendoAgent = false; refreshNextendoAgentState() }
        do {
            if enabled {
                try nextendoAgentService.register()
                UserDefaults.standard.set(bundledAgentCDHash, forKey: Self.registeredAgentKey)
                refreshNextendoAgentState()
                if nextendoAgentState == .on { await registerInstalledPortsWithNextendoAgent() }
            } else {
                try await nextendoAgentService.unregister()
                UserDefaults.standard.removeObject(forKey: Self.registeredAgentKey)
            }
        } catch {
            refreshNextendoAgentState()
            if nextendoAgentState != .needsApproval {
                nextendoAgentMessage = t("macOS did not change the background agent. Try again, or check Login Items in System Settings.")
            }
        }
    }

    func openNextendoAgentApproval() { SMAppService.openSystemSettingsLoginItems() }

    /// A port built or installed before the agent was on is registered here; any
    /// other port keeps signing in by itself.
    func registerInstalledPortsWithNextendoAgent() async {
        var registered = 0, failed = 0
        for app in Self.installedMacPorts() {
            switch await nextendoAgentClient.registerPeer(app: app) {
            case .ok?: registered += 1
            default: failed += 1
            }
        }
        if failed > 0 {
            nextendoAgentMessage = t("Some installed games could not be registered with the background agent; they sign in by themselves.")
        } else if registered > 0 {
            appendLog("Registered \(registered) installed game(s) with the Nextendo agent.")
        }
    }

    /// After a Mac port is installed: the agent accepts only code Studio registered.
    func registerPortWithNextendoAgent(_ app: URL) async {
        refreshNextendoAgentState()
        guard nextendoAgentState == .on else { return }
        if await nextendoAgentClient.registerPeer(app: app) != .ok {
            appendLog("The Nextendo agent did not register this game; it will sign in by itself.")
        }
    }

    /// Sign-in, sign-out and new game credentials reach running ports through the agent.
    func notifyNextendoAgentAccountChanged() {
        guard nextendoAgentState == .on else { return }
        let client = nextendoAgentClient
        Task { _ = await client.accountDidChange() }
    }

    // MARK: Hub

    /// Friends and the notification switch come from the agent, which polls for them.
    func refreshNextendoFriends() async {
        guard nextendoAgentState == .on, nextendoAccount != nil else { nextendoFriends = nil; return }
        guard !isLoadingNextendoFriends else { return }
        isLoadingNextendoFriends = true; defer { isLoadingNextendoFriends = false }
        if let enabled = await nextendoAgentClient.notifications() { nextendoNotifications = enabled }
        nextendoGameNames = await Task.detached { NextendoInstalledGames.names() }.value
        switch await nextendoAgentClient.friends() {
        case let result? where result.status == .ok:
            nextendoFriends = result.view; nextendoFriendsMessage = nil
        case let result? where result.status == .signedOut:
            nextendoFriends = nil; nextendoFriendsMessage = nil
        default:
            nextendoFriendsMessage = t("The background agent could not read your friends. Try again later.")
        }
    }

    func answerNextendoFriendRequest(_ friend: NextendoFriend, accept: Bool) async {
        guard !nextendoFriendAnswers.contains(friend.pid) else { return }
        nextendoFriendAnswers.insert(friend.pid); defer { nextendoFriendAnswers.remove(friend.pid) }
        let result = await nextendoAgentClient.answerFriendRequest(friend.pid, accept: accept)
        if result?.status == .ok, let http = result?.http, (200..<300).contains(http) {
            await refreshNextendoFriends()
        } else {
            nextendoFriendsMessage = t("Nextendo did not accept the answer to this friend request.")
        }
    }

    func setNextendoNotifications(_ enabled: Bool) async {
        guard !isChangingNextendoNotifications else { return }
        isChangingNextendoNotifications = true; defer { isChangingNextendoNotifications = false }
        let result = await nextendoAgentClient.setNotifications(enabled)
        nextendoNotifications = result ?? false
        if enabled && result != true {
            nextendoFriendsMessage = t("macOS did not allow notifications. Allow them for NX Port Studio in System Settings, Notifications.")
        }
    }

    nonisolated static func installedMacPorts(in folders: [URL] = [URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return apps.filter { app in
                guard app.pathExtension == "app",
                      let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return false }
                return info["DMPrimaryHost"] as? Bool == true && info["DMTitleID"] is String
            }
        }
    }
}
