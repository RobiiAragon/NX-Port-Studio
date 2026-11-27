import Foundation

/// A native Mac port found in an Applications folder, read from its `Info.plist` only
/// (dm/mac/pack_app.py writes the keys); its game files are never opened.
public struct InstalledMacPort: Identifiable, Hashable, Sendable {
    public let appURL: URL
    public let titleID: String
    public let name: String
    public let bundleIdentifier: String
    public let stateURL: URL
    /// `CFBundleShortVersionString`: the game version the port was packed from.
    public let version: String
    /// `DMPrimaryHost`: the app's executable is the native host itself. Ports packed
    /// before it (a `dmhost` beside a launcher) still keep saves but cannot be launched
    /// with the settings window, sign in by themselves or register with the agent.
    public let isPrimaryHost: Bool
    /// `DMEngine` and `DMEngineTime`; nil for a port packed before the stamp.
    public let engine: PortEngineStamp?
    public var id: String { appURL.path }
    public var primarySaveURL: URL { stateURL.appendingPathComponent("save", isDirectory: true) }
    public var deviceSaveURL: URL { stateURL.appendingPathComponent("save_device", isDirectory: true) }

    public init(appURL: URL, titleID: String, name: String, bundleIdentifier: String, stateURL: URL,
                version: String = "", isPrimaryHost: Bool = true, engine: PortEngineStamp? = nil) {
        self.appURL = appURL; self.titleID = titleID; self.name = name
        self.bundleIdentifier = bundleIdentifier; self.stateURL = stateURL
        self.version = version; self.isPrimaryHost = isPrimaryHost; self.engine = engine
    }
}

/// The one discovery of installed Mac ports, shared by Studio's Library, Saved games and
/// Nextendo pages and by the Nextendo agent.
public enum InstalledMacPorts {
    public static var defaultFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Apps directly in `directories` whose `Info.plist` names a valid title ID and a bundle
    /// identifier, sorted by name. Symbolic links and hidden items are skipped.
    public static func scan(in directories: [URL] = defaultFolders,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledMacPort] {
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
                    bundleIdentifier: bundle, stateURL: state.appendingPathComponent(title, isDirectory: true),
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    isPrimaryHost: info["DMPrimaryHost"] as? Bool == true,
                    engine: PortEngineStamp(info: info)))
            }
        }
        return ports.sorted { ($0.name, $0.appURL.path) < ($1.name, $1.appURL.path) }
    }
}

/// The engine a port was packed from (`DMEngine`, `DMEngineTime` in its `Info.plist`) or the
/// engine Studio builds with. `revision` is Studio's engine snapshot (`ENGINE_REVISION`:
/// commit and content hash) or a checkout's short commit, `+dirty` with uncommitted changes;
/// `time` is that commit's committer time (Unix seconds), which orders two revisions.
public struct PortEngineStamp: Hashable, Sendable {
    public let revision: String
    public let time: Int?

    public init(revision: String, time: Int?) { self.revision = revision; self.time = time }

    public init?(info: [String: Any]) {
        guard let revision = info["DMEngine"] as? String, !revision.isEmpty else { return nil }
        self.init(revision: revision, time: (info["DMEngineTime"] as? NSNumber)?.intValue)
    }

    /// The engine at `repository`, read as dm/mac/pack_app.py (`engine_stamp`) reads it: a
    /// Studio snapshot's `ENGINE_REVISION` and `ENGINE_TIME` files, else git in a checkout.
    /// Git runs only where `.git` exists, so a Mac without the developer tools never sees
    /// their install prompt.
    public static func of(repository: URL, git: (URL, [String]) -> String? = runGit) -> PortEngineStamp? {
        func file(_ name: String) -> String? {
            (try? String(contentsOf: repository.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let revision = file("ENGINE_REVISION"), !revision.isEmpty {
            return PortEngineStamp(revision: revision, time: file("ENGINE_TIME").flatMap { Int($0) })
        }
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path),
              let head = git(repository, ["rev-parse", "--short=12", "HEAD"]), !head.isEmpty else { return nil }
        let dirty = !(git(repository, ["status", "--porcelain", "--untracked-files=no"]) ?? "").isEmpty
        let time = git(repository, ["log", "-1", "--format=%ct", "HEAD"]).flatMap { Int($0) }
        return PortEngineStamp(revision: head + (dirty ? "+dirty" : ""), time: time)
    }

    public static func runGit(_ repository: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How a port's engine compares with the one Studio builds with now.
public enum PortEngineAge: Equatable, Sendable {
    /// Packed from the same engine.
    case current
    /// Packed from an earlier commit: rebuilding picks up the newer host fixes.
    case older
    /// Packed from a later commit than Studio's engine.
    case newer
    /// Another revision of the same commit (local changes), or one without a commit time.
    case different
    /// Packed before ports carried an engine stamp.
    case unstamped
    /// Studio's own engine is not known (not prepared yet, or a folder without a stamp).
    case unknown

    public static func of(_ port: PortEngineStamp?, against studio: PortEngineStamp?) -> PortEngineAge {
        guard let port else { return .unstamped }
        guard let studio else { return .unknown }
        if port.revision == studio.revision { return .current }
        guard let portTime = port.time, let studioTime = studio.time, portTime != studioTime else { return .different }
        return portTime < studioTime ? .older : .newer
    }
}
