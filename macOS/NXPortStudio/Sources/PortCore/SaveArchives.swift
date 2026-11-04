import Foundation
import CSaveArchive

public struct InstalledMacPort: Identifiable, Hashable, Sendable {
    public let appURL: URL
    public let titleID: String
    public let name: String
    public let bundleIdentifier: String
    public let stateURL: URL
    public var id: String { appURL.path }
    public var primarySaveURL: URL { stateURL.appendingPathComponent("save", isDirectory: true) }
    public var deviceSaveURL: URL { stateURL.appendingPathComponent("save_device", isDirectory: true) }

    public init(appURL: URL, titleID: String, name: String, bundleIdentifier: String, stateURL: URL) {
        self.appURL = appURL; self.titleID = titleID; self.name = name
        self.bundleIdentifier = bundleIdentifier; self.stateURL = stateURL
    }
}

public enum SaveSlot: String, CaseIterable, Identifiable, Sendable {
    case primary = "save", device = "save_device"
    public var id: String { rawValue }
}

public struct SaveArchiveOutcome: Sendable {
    public let fileCount: UInt64
    public let byteCount: UInt64
    public let backupURL: URL?
    /// Publication already happened; a durability warning must never be
    /// displayed as a failed import that is safe to retry automatically.
    public let durabilityWarning: String?
}

public enum SaveArchiveStore {
    public static func installedPorts(in directories: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledMacPort] {
        let fm = FileManager.default
        let state = home.appendingPathComponent("Library/Application Support/nxnative", isDirectory: true)
        var ports: [InstalledMacPort] = []
        for directory in directories {
            let apps = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            for app in apps where app.pathExtension.lowercased() == "app" {
                guard let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let title = info["DMTitleID"] as? String,
                      title.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil,
                      UInt64(title, radix: 16) != 0,
                      let bundle = info["CFBundleIdentifier"] as? String, !bundle.isEmpty else { continue }
                let titleID = title.uppercased()
                ports.append(InstalledMacPort(appURL: app, titleID: titleID,
                    name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundle, stateURL: state.appendingPathComponent(title, isDirectory: true)))
            }
        }
        return ports.sorted { ($0.name, $0.appURL.path) < ($1.name, $1.appURL.path) }
    }

    public static func hasSave(_ port: InstalledMacPort, slot: SaveSlot) -> Bool {
        let path = port.stateURL.appendingPathComponent(slot.rawValue)
        guard let values = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    public static func importArchive(from archive: URL, into port: InstalledMacPort, slot: SaveSlot) throws -> SaveArchiveOutcome {
        guard let title = UInt64(port.titleID, radix: 16), title != 0 else { throw PortError.invalidConfiguration("Invalid game title ID.") }
        let fm = FileManager.default
        try fm.createDirectory(at: port.stateURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An additional device tree proves that the primary tree is the
        // separate account save. A single primary tree can be account/device.
        let kind: Int32 = slot == .device ? 3 : hasSave(port, slot: .device) ? 1 : -1
        var result = dm_save_archive_operation()
        let error = archive.path.withCString { zip in
            port.stateURL.path.withCString { root in
                slot.rawValue.withCString { save in dm_save_archive_import(zip, root, save, title, kind, &result) }
            }
        }
        return try outcome(result, error: error)
    }

    public static func exportArchive(from port: InstalledMacPort, slot: SaveSlot, to archive: URL) throws -> SaveArchiveOutcome {
        var result = dm_save_archive_operation()
        let error = port.stateURL.path.withCString { root in
            slot.rawValue.withCString { save in
                archive.path.withCString { zip in dm_save_archive_export(root, save, zip, &result) }
            }
        }
        return try outcome(result, error: error)
    }

    private static func outcome(_ result: dm_save_archive_operation, error: Int32) throws -> SaveArchiveOutcome {
        let message = String(cString: dm_save_archive_error(error))
        guard result.installed != 0 else {
            let detail = error == EWOULDBLOCK ? "Close the game before managing its saves." :
                error == EEXIST ? "Choose a new ZIP filename. Existing archives are never overwritten." : message
            throw PortError.invalidConfiguration(detail)
        }
        let backup = withUnsafeBytes(of: result.backup_path) { bytes in
            bytes.withMemoryRebound(to: CChar.self) { chars in
                chars.first == 0 ? nil : URL(fileURLWithPath: String(cString: chars.baseAddress!))
            }
        }
        return SaveArchiveOutcome(fileCount: result.info.files, byteCount: result.info.bytes,
                                  backupURL: backup, durabilityWarning: error == 0 ? nil : message)
    }
}
