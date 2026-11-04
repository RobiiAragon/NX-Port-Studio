// Shared save controls in the native Mac/iPhone launchers. Imports are applied
// before the guest can mount a save; iOS queues them for the next cold launch.
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct NativeSaveLocation: Sendable {
    let root: URL
    let title: UInt64
    static func current() -> Self? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = (info["DMTitleID"] ?? info["DMGameTitleID"]) as? String,
              id.count == 16, let title = UInt64(id, radix: 16), title != 0 else { return nil }
        let root: URL
        if let path = ProcessInfo.processInfo.environment["DM_SAVE"] {
            let save = URL(fileURLWithPath: path)
            guard save.lastPathComponent == "save" else { return nil }
            root = save.deletingLastPathComponent()
        } else {
#if os(macOS)
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/\(id)")
#else
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
#endif
        }
        return Self(root: root, title: title)
    }
}

private struct NativeSaveOutcome: Sendable {
    let error: Int32
    let published: Bool
    let backup: String
    static func read(_ op: dm_save_archive_operation, _ error: Int32) -> Self {
        let path = withUnsafeBytes(of: op.backup_path) { bytes in
            bytes.withMemoryRebound(to: CChar.self) { String(cString: $0.baseAddress!) }
        }
        return Self(error: error, published: op.installed != 0, backup: path)
    }
}

struct LauncherSavesSection: View {
    let language: LauncherUILanguage
    @Binding var busy: Bool
    @Binding var needsRestart: Bool
    @State private var slot = "save"
    @State private var picking = false
    @State private var selectedImport: URL?
    @State private var selectedSlot = "save"
    @State private var confirming = false
    @State private var message = ""
    @State private var detail = ""
    @State private var sharedZIP: URL?
    @State private var folderToBrowse: SaveBrowserFolder?
    private let location = NativeSaveLocation.current()
    private func tx(_ key: String) -> String { launcherText(key, language: language) }

    var body: some View {
        Section {
            if let location {
                Picker(tx("Save type"), selection: $slot) {
                    Text(tx("Main save")).tag("save")
                    Text(tx("Device save")).tag("save_device")
                }
                Button(tx("Import JKSV ZIP")) { chooseImport() }
                Button(tx("Export JKSV ZIP")) { export(location) }
                    .disabled(!FileManager.default.fileExists(atPath: location.root.appendingPathComponent(slot).path))
                if let sharedZIP {
                    ShareLink(item: sharedZIP) { Label(tx("Share exported ZIP"), systemImage: "square.and.arrow.up") }
                }
                Button(tx("Open save folder")) { openFolder(location.root.appendingPathComponent(slot)) }
                Button(tx("Open backups")) { openFolder(location.root.appendingPathComponent("save-backups")) }
                if needsRestart {
                    Text(tx("Restart this port before playing. The import is applied before the game loads.")).foregroundStyle(.orange)
                    if dm_save_archive_has_pending(location.root.path) != 0 {
                        Button(tx("Cancel pending import"), role: .destructive) {
                            let error = dm_save_archive_cancel_pending(location.root.path)
                            message = error == 0 ? "Pending import canceled. Reopen the port to play." : String(cString: dm_save_archive_error(error))
                        }
                    }
                }
                if busy { ProgressView(tx("Processing saved game…")) }
                if !message.isEmpty { Text(tx(message)).font(.footnote).textSelection(.enabled) }
                if !detail.isEmpty { Text(verbatim: detail).font(.footnote).textSelection(.enabled) }
            } else {
                Text(tx("Save controls require the port's standard save directory."))
            }
        } header: {
            Text(tx("Saved games"))
        } footer: {
            Text(tx("JKSV ZIP files contain save files at the root. Main save also covers games with device-only saves. Choose Device save only for games that keep an additional, separate device save. Previous saves are kept in Backups."))
        }
        .disabled(busy)
        .onAppear {
            if let location, dm_save_archive_has_pending(location.root.path) != 0 { needsRestart = true }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): selectedImport = url; selectedSlot = slot; confirming = true
            case .failure(let error): message = ""; detail = error.localizedDescription
            }
        }
        .alert(tx("Import saved game?"), isPresented: $confirming) {
            Button(tx("Cancel"), role: .cancel) { selectedImport = nil }
            Button(tx("Import JKSV ZIP"), role: .destructive) {
                if let url = selectedImport, let location { restore(url, location: location, slot: selectedSlot) }
                selectedImport = nil
            }
        } message: {
            Text(tx("This replaces the selected save. The previous save is retained in Backups. ZIPs without JKSV metadata cannot identify their game; check that you selected the right backup."))
        }
        .sheet(item: $folderToBrowse) { folder in
            NavigationStack { SaveFolderBrowser(folder: folder.url, language: language) }
        }
    }

    private func chooseImport() {
#if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedImport = url; selectedSlot = slot; confirming = true
#else
        picking = true
#endif
    }

    private func restore(_ archive: URL, location: NativeSaveLocation, slot: String) {
        busy = true; message = ""; detail = ""
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                let access = archive.startAccessingSecurityScopedResource()
                defer { if access { archive.stopAccessingSecurityScopedResource() } }
                do { try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { return NativeSaveOutcome(error: EACCES, published: false, backup: "") }
                let kind: Int32 = slot == "save_device" ? 3 : FileManager.default.fileExists(atPath: location.root.appendingPathComponent("save_device").path) ? 1 : -1
                var op = dm_save_archive_operation()
#if os(macOS)
                let error = dm_save_archive_import(archive.path, location.root.path, slot, location.title, kind, &op)
#else
                let error = dm_save_archive_queue(archive.path, location.root.path, slot, location.title, kind, &op)
#endif
                return NativeSaveOutcome.read(op, error)
            }.value
            busy = false
            if outcome.published {
#if os(iOS)
                needsRestart = true; message = "Import prepared. Reopen the port to apply it."
#else
                message = "Saved game imported."
#endif
                detail = outcome.backup
                if outcome.error != 0 { message = "The save was published, but the disk reported a durability warning."; detail = tx(String(cString: dm_save_archive_error(outcome.error))) }
            } else { message = outcome.error == EWOULDBLOCK ? "Close the game before managing its saves." : String(cString: dm_save_archive_error(outcome.error)) }
        }
    }

    private func export(_ location: NativeSaveLocation) {
        let selectedSlot = slot
        let name = String(format: "%016llX-%@-%@.zip", location.title, selectedSlot, ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
        let output: URL
#if os(macOS)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }; output = url
#else
        output = FileManager.default.temporaryDirectory.appendingPathComponent("jksv-export-\(UUID().uuidString)-\(name)")
#endif
        busy = true; message = ""; detail = ""; sharedZIP = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                var op = dm_save_archive_operation()
#if os(macOS)
                let error = dm_save_archive_export(location.root.path, selectedSlot, output.path, &op)
#else
                let error = dm_launcher_save_export(location.root.path, selectedSlot, output.path, &op)
#endif
                return NativeSaveOutcome.read(op, error)
            }.value
            busy = false
            if outcome.published {
                sharedZIP = output; message = "Saved game exported."
                if outcome.error != 0 { message = "The save was published, but the disk reported a durability warning."; detail = tx(String(cString: dm_save_archive_error(outcome.error))) }
            } else { message = outcome.error == EEXIST ? "Choose a new ZIP filename. Existing archives are never overwritten." : String(cString: dm_save_archive_error(outcome.error)) }
        }
    }

    private func openFolder(_ url: URL) {
#if os(macOS)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { message = "No saved game exists in this folder yet." }
#else
        folderToBrowse = SaveBrowserFolder(url: url)
#endif
    }
}

private struct SaveBrowserFolder: Identifiable { let url: URL; var id: URL { url } }
private struct SaveFolderBrowser: View {
    let folder: URL
    let language: LauncherUILanguage
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [URL] = []
    @State private var error = ""
    var body: some View {
        List {
            if !error.isEmpty { Text(verbatim: error) }
            ForEach(entries, id: \.self) { url in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NavigationLink { SaveFolderBrowser(folder: url, language: language) } label: { Label(url.lastPathComponent, systemImage: "folder") }
                } else {
                    ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "doc") }
                }
            }
        }
        .navigationTitle(folder.lastPathComponent)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(launcherText("Done", language: language)) { dismiss() } } }
        .task(id: folder) {
            do {
                entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                    (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { self.error = error.localizedDescription }
        }
    }
}

func nativeSaveImportCanSkipLauncher() -> Bool {
    guard let location = NativeSaveLocation.current() else { return true }
    return dm_save_archive_has_pending(location.root.path) == 0
}
