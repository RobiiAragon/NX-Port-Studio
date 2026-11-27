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
            (InstalledMacPorts.scan().filter(\.isPrimaryHost), repository.flatMap { PortEngineStamp.of(repository: $0) })
        }.value
        libraryPorts = ports; studioEngine = engine
        refreshRunningLibraryPorts()
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
