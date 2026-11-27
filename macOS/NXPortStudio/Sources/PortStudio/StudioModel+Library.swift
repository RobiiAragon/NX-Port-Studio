import AppKit
import PortCore

/// What the Library shows: the home screen (games and shortcuts) or the friends screen.
enum LibraryScreen: Equatable { case home, friends }
/// The home screen's two rows, as on a console's home menu: games above, shortcuts below.
enum LibraryRow: Equatable { case games, shortcuts }
enum LibraryFriendsSection: CaseIterable, Equatable { case friends, received, sent, add }

/// The round buttons under the games.
enum LibraryShortcut: CaseIterable, Equatable {
    case friends, newPort, saves, nextendo, fullScreen
    var icon: String {
        switch self {
        case .friends: "person.2.fill"
        case .newPort: "plus"
        case .saves: "externaldrive.fill"
        case .nextendo: "network"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// The keys the Library answers, whatever sends them (the keyboard now, a controller later).
enum LibraryKey: Equatable { case left, right, up, down, activate, alternate, back, fullScreen }

/// The Library page: Studio as a front end for the Mac ports already installed. Each
/// port runs, signs in to Nextendo and reads its bundled routes by itself; Studio only
/// opens it, as Finder or the Dock would (docs/frontends.md, Studio's Library).
extension StudioModel {
    func reloadLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true; defer { isLoadingLibrary = false }
        let repository = repositoryPath.isEmpty ? nil : URL(fileURLWithPath: repositoryPath)
        let (ports, engine) = await Task.detached {
            (InstalledMacPorts.recentlyPlayedFirst(InstalledMacPorts.scan().filter(\.isPrimaryHost)), repository.flatMap { PortEngineStamp.of(repository: $0) })
        }.value
        libraryPorts = ports; studioEngine = engine
        if librarySelection.map({ id in !ports.contains { $0.id == id } }) ?? true { librarySelection = ports.first?.id }
        refreshRunningLibraryPorts()
    }

    var selectedLibraryPort: InstalledMacPort? { libraryPorts.first { $0.id == librarySelection } ?? libraryPorts.first }

    /// Moves the focus along the row (arrow keys); it stops at both ends.
    func moveLibrarySelection(by step: Int) {
        guard !libraryPorts.isEmpty else { return }
        let index = libraryPorts.firstIndex { $0.id == selectedLibraryPort?.id } ?? 0
        librarySelection = libraryPorts[min(max(index + step, 0), libraryPorts.count - 1)].id
    }

    /// One key on the Library. Returns false for a key it does not use here.
    @discardableResult
    func handleLibraryKey(_ key: LibraryKey) -> Bool {
        switch (libraryScreen, key) {
        case (_, .fullScreen):
            setLibraryFullScreen(!libraryFullScreen)
        case (.friends, .up), (.friends, .down):
            let sections = LibraryFriendsSection.allCases
            let index = sections.firstIndex(of: libraryFriendsSection) ?? 0
            libraryFriendsSection = sections[min(max(index + (key == .up ? -1 : 1), 0), sections.count - 1)]
        case (.friends, .back):
            libraryScreen = .home
        case (.home, .back):
            guard libraryFullScreen else { return false }
            setLibraryFullScreen(false)
        case (.home, .down) where libraryRow == .games:
            libraryRow = .shortcuts
        case (.home, .up) where libraryRow == .shortcuts:
            libraryRow = .games
        case (.home, .left), (.home, .right):
            let step = key == .left ? -1 : 1
            if libraryRow == .games { moveLibrarySelection(by: step) }
            else { libraryShortcut = min(max(libraryShortcut + step, 0), LibraryShortcut.allCases.count - 1) }
        case (.home, .activate), (.home, .alternate):
            if libraryRow == .shortcuts { runLibraryShortcut(LibraryShortcut.allCases[libraryShortcut]); return true }
            guard let port = selectedLibraryPort else { return false }
            let settings = key == .alternate && port.engine != nil && !libraryPortIsRunning(port)
            Task { await openLibraryPort(port, settings: settings) }
        default:
            return false
        }
        return true
    }

    func runLibraryShortcut(_ shortcut: LibraryShortcut) {
        libraryShortcut = LibraryShortcut.allCases.firstIndex(of: shortcut) ?? 0
        switch shortcut {
        case .friends: libraryScreen = .friends
        case .fullScreen: setLibraryFullScreen(!libraryFullScreen)
        case .newPort: leaveLibrary(to: .create)
        case .saves: leaveLibrary(to: .saves)
        case .nextendo: leaveLibrary(to: .nextendo)
        }
    }

    func leaveLibrary(to page: StudioPage) {
        setLibraryFullScreen(false)
        libraryScreen = .home
        self.page = page
    }

    /// The friend list as the friends screen shows it: best friends first, then online
    /// (playing before only online), then by name.
    var libraryFriends: [NextendoFriend] {
        (nextendoFriends?.friends ?? []).sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            if a.status != b.status { return a.status > b.status }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Add friend: sends a request to the friend code typed in, through the agent.
    func sendLibraryFriendRequest() async {
        guard !isSendingFriendRequest else { return }
        guard let code = NextendoFriendCode.normalized(libraryFriendCode) else {
            libraryFriendRequestResult = (false, t("Type a friend code: SW and twelve digits."))
            return
        }
        if code == nextendoAccount?.identity?.friendCode {
            libraryFriendRequestResult = (false, t("This is your own friend code."))
            return
        }
        isSendingFriendRequest = true; defer { isSendingFriendRequest = false }
        let result = await nextendoAgentClient.sendFriendRequest(code)
        switch (result?.status, result?.http ?? 0) {
        case (.ok?, 200..<300):
            libraryFriendRequestResult = (true, result?.already == true ? t("A request to this player was already waiting.") : t("Friend request sent."))
            libraryFriendCode = ""
            await refreshNextendoFriends()
        case (.ok?, 404):
            libraryFriendRequestResult = (false, t("No player has this friend code."))
        case (.ok?, 400):
            libraryFriendRequestResult = (false, t("Nextendo did not accept this request."))
        case (nil, _):
            libraryFriendRequestResult = (false, t("The background agent cannot send friend requests yet. Quit and reopen NX Port Studio so it updates the agent."))
        default:
            libraryFriendRequestResult = (false, t("Nextendo did not accept this request."))
        }
    }

    func libraryFriendActivity(_ friend: NextendoFriend) -> String {
        if let title = friend.titleID, let game = nextendoGameNames[title] { return String(format: t("Playing %@"), game) }
        switch friend.status {
        case 2: return t("In a game")
        case 1: return t("Online")
        default: return t("Offline")
        }
    }

    /// Friends online for the top bar: only from the Nextendo agent's hub, when it runs.
    func refreshLibraryFriends() async {
        refreshNextendoAgentState()
        await refreshNextendoFriends()
    }

    var libraryFriendsOnline: Int? { nextendoFriends.map { $0.friends.filter(\.isOnline).count } }

    /// The Library alone in the window; the window goes full screen too, and leaves it on
    /// the way out only when the Library put it there.
    func setLibraryFullScreen(_ on: Bool) {
        guard on != libraryFullScreen else { return }
        libraryFullScreen = on
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let isFull = window?.styleMask.contains(.fullScreen) == true
        if on, !isFull { libraryOwnsWindowFullScreen = true; window?.toggleFullScreen(nil) }
        if !on {
            if isFull, libraryOwnsWindowFullScreen { window?.toggleFullScreen(nil) }
            libraryOwnsWindowFullScreen = false
        }
    }

    func refreshRunningLibraryPorts() {
        runningLibraryPorts = Set(libraryPorts.map(\.bundleIdentifier).filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
    }

    func libraryPortIsRunning(_ port: InstalledMacPort) -> Bool { runningLibraryPorts.contains(port.bundleIdentifier) }

    func engineAge(of port: InstalledMacPort) -> PortEngineAge { PortEngineAge.of(port.engine, against: studioEngine) }

    /// Opens the port, or brings it forward when it already runs. `settings` asks the
    /// port's launcher for its settings window even when the player turned "Show this
    /// window at launch" off: Studio cannot hold Option for the port it opens, so it passes
    /// `DM_LAUNCHER=1`, which dm/mac/Launcher.swift reads as the Option key.
    func openLibraryPort(_ port: InstalledMacPort, settings: Bool = false) async {
        libraryMessage = nil
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: port.bundleIdentifier).first {
            running.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        if settings { configuration.environment = ["DM_LAUNCHER": "1"] }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: port.appURL, configuration: configuration)
        } catch {
            libraryMessage = String(format: t("%@ could not be opened: %@"), port.name, error.localizedDescription)
        }
        refreshRunningLibraryPorts()
    }

    func showLibraryPortInFinder(_ port: InstalledMacPort) {
        NSWorkspace.shared.activateFileViewerSelecting([port.appURL])
    }
}
