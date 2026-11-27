import Foundation
import CSaveArchive

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
