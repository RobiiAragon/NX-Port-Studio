import AppKit
import PortCore

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
