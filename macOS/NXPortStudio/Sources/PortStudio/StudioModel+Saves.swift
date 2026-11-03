import AppKit
import Foundation
import PortCore
import UniformTypeIdentifiers

extension StudioModel {
    var selectedSavePort: InstalledMacPort? { savePorts.first { $0.id == selectedSavePortID } }

    func reloadSavePorts() async {
        guard !isLoadingSavePorts, !isManagingSaves else { return }
        isLoadingSavePorts = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        savePorts = await Task.detached { SaveArchiveStore.installedPorts(in: directories, home: home) }.value
        if selectedSavePort == nil { selectedSavePortID = savePorts.first?.id ?? "" }
        selectedSaveSlot = .primary
        isLoadingSavePorts = false
    }

    func savePortIsRunning(_ port: InstalledMacPort) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if app.bundleIdentifier == port.bundleIdentifier { return true }
            guard let bundle = app.bundleURL,
                  let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return (info["DMTitleID"] as? String)?.uppercased() == port.titleID
        }
    }

    private func canManageSaves(_ port: InstalledMacPort) -> Bool {
        guard !isBusy, !isManagingSaves else { return false }
        guard !savePortIsRunning(port) else {
            saveArchiveError = t("Close the game before managing its saves.")
            return false
        }
        saveArchiveError = nil; saveArchiveMessage = nil; lastSaveBackupURL = nil
        return true
    }

    func chooseSaveImport() {
        guard let port = selectedSavePort, canManageSaves(port) else { return }
        let slot = selectedSaveSlot
        let panel = NSOpenPanel()
        panel.title = t("Import JKSV ZIP")
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = t("Import this backup?")
        alert.informativeText = port.name + "\n" + t(slot == .device ? "Device save" : "Main save") + "\n\n" + t("This replaces the selected save. The previous save is retained in Backups. ZIPs without JKSV metadata cannot identify their game; check that you selected the right backup.")
        alert.addButton(withTitle: t("Import backup")); alert.addButton(withTitle: t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, canManageSaves(port) else { return }
        isManagingSaves = true
        Task {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() }; isManagingSaves = false }
            do {
                let result = try await Task.detached { try SaveArchiveStore.importArchive(from: source, into: port, slot: slot) }.value
                lastSaveBackupURL = result.backupURL
                saveArchiveMessage = t(result.durabilityWarning == nil ? "Backup imported. The game will read it on its next launch." : "The save was imported, but its disk synchronization could not be confirmed. Keep the previous backup.")
                if let warning = result.durabilityWarning { saveArchiveError = t(warning) }
            } catch { saveArchiveError = t(error.localizedDescription) }
        }
    }

    func chooseSaveExport() {
        guard let port = selectedSavePort, canManageSaves(port) else { return }
        let slot = selectedSaveSlot
        guard SaveArchiveStore.hasSave(port, slot: slot) else { saveArchiveError = t("This port has no saved game yet."); return }
        let panel = NSSavePanel()
        panel.title = t("Export JKSV ZIP")
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = port.titleID + "-" + slot.rawValue + "-" + date.string(from: Date()) + ".zip"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url, canManageSaves(port) else { return }
        isManagingSaves = true
        Task {
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() }; isManagingSaves = false }
            do {
                let result = try await Task.detached { try SaveArchiveStore.exportArchive(from: port, slot: slot, to: destination) }.value
                saveArchiveMessage = t(result.durabilityWarning == nil ? "JKSV ZIP exported. Restore it to the same game and save type on your Switch." : "The ZIP was exported, but its disk synchronization could not be confirmed.")
                if let warning = result.durabilityWarning { saveArchiveError = t(warning) }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { saveArchiveError = t(error.localizedDescription) }
        }
    }

    func openSelectedSaveFolder() {
        guard let port = selectedSavePort else { return }
        let folder = port.stateURL.appendingPathComponent(selectedSaveSlot.rawValue, isDirectory: true)
        guard SaveArchiveStore.hasSave(port, slot: selectedSaveSlot) else { saveArchiveError = t("This port has no saved game yet."); return }
        NSWorkspace.shared.open(folder)
    }

    func openSaveBackups() {
        guard let port = selectedSavePort else { return }
        if let lastSaveBackupURL { NSWorkspace.shared.activateFileViewerSelecting([lastSaveBackupURL]); return }
        let folder = port.stateURL.appendingPathComponent("save-backups", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { saveArchiveError = error.localizedDescription }
    }
}
