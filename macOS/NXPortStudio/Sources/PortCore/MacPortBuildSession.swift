import Foundation
import Darwin

/// A build owns one private directory beside its installed application. All game
/// intermediates and the staged app live here, on the install volume. The caller
/// removes it after the process group has exited, including cancellation.
public final class MacPortBuildSession: Sendable {
    public let rootURL: URL
    public let workURL: URL
    public let engineURL: URL
    public let applicationURL: URL
    public let destinationURL: URL
    private static let prefix = ".nx-port-build-"
    private struct Owner: Codable { let pid: Int32; let uid: UInt32 }

    public init(destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent().resolvingSymlinksInPath()
        self.destinationURL = parent.appendingPathComponent(destinationURL.lastPathComponent)
        guard destinationURL.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            throw PortError.invalidConfiguration("Applications is not writable. Choose a writable Applications folder before building.")
        }
        try Self.checkDestination(self.destinationURL)
        rootURL = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        workURL = rootURL.appendingPathComponent("work", isDirectory: true)
        engineURL = rootURL.appendingPathComponent("engine", isDirectory: true)
        applicationURL = rootURL.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try JSONEncoder().encode(Owner(pid: getpid(), uid: getuid()))
                .write(to: rootURL.appendingPathComponent("owner.json"), options: .atomic)
            try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: false)
        } catch { try? FileManager.default.removeItem(at: rootURL); throw error }
    }

    /// Host/profile generation and .NET also write beside their source files.
    /// Isolate those writes, rather than leaving build residue in the managed
    /// engine or in a user's source checkout. Persistent developer caches are
    /// deliberately excluded from this per-build snapshot.
    public func prepareEngine(from repository: URL, using runner: ProcessRunner) async throws {
        try FileManager.default.createDirectory(at: engineURL, withIntermediateDirectories: false)
        let exclusions = [".git/", ".local/", ".build/", "__pycache__/", "*.pyc", "obj/", "bin/", "*.dSYM/", "host/gen/", "host/dmhost", "ios/Gen/"]
        let arguments = ["-a"] + exclusions.map { "--exclude=" + $0 } +
            [repository.appendingPathComponent("dm").path, repository.appendingPathComponent("scripts").path, engineURL.path + "/"]
        let result = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/rsync"), arguments: arguments))
        guard result.exitCode == 0 else { throw PortError.processFailed(result.exitCode, "Could not prepare the temporary build engine.") }
        try Task.checkCancellation()
    }

    private static func metadata(_ app: URL) throws -> [String: Any] {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: app.path)) == nil,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let title = info["DMTitleID"] as? String,
              title.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil,
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw PortError.invalidConfiguration("The destination already exists and is not a recognized game port. Use another app name.")
        }
        let primary = info["DMPrimaryHost"] as? Bool == true
        let code = primary ? ["Contents/MacOS/nxnative", "Contents/Frameworks/DMMacBootstrap.dylib", "Contents/Helpers/dm-save-supervisor"] : ["Contents/MacOS/dmhost"]
        guard code.allSatisfy({ fm.isExecutableFile(atPath: app.appendingPathComponent($0).path) }),
              !primary || info["CFBundleExecutable"] as? String == "nxnative" else {
            throw PortError.invalidConfiguration("The game port is missing its executable or bootstrap. Build it again before installing.")
        }
        return info
    }

    private static func checkDestination(_ app: URL) throws {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: app.path)) == nil else {
            throw PortError.invalidConfiguration("The application destination must not be a symbolic link.")
        }
        if fm.fileExists(atPath: app.path) { _ = try metadata(app) }
    }

    /// Verify the complete app before the only operation that changes the installed
    /// version. RENAME_SWAP keeps the previous version in our owned scratch folder;
    /// a failed verification or rename leaves the installed version untouched.
    public func install(using runner: ProcessRunner) async throws -> URL {
        let newInfo = try Self.metadata(applicationURL)
        let verified = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", applicationURL.path]))
        guard verified.exitCode == 0 else {
            throw PortError.processFailed(verified.exitCode, "The Mac app failed signature verification.")
        }
        try Task.checkCancellation()
        try Self.checkDestination(destinationURL)
        let exists = FileManager.default.fileExists(atPath: destinationURL.path)
        if exists {
            let oldInfo = try Self.metadata(destinationURL)
            guard (oldInfo["DMTitleID"] as? String)?.uppercased() == (newInfo["DMTitleID"] as? String)?.uppercased(),
                  oldInfo["CFBundleIdentifier"] as? String == newInfo["CFBundleIdentifier"] as? String else {
                throw PortError.invalidConfiguration("Another game uses this app name. Choose a different name before installing.")
            }
        }
        let flags = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
        guard renamex_np(applicationURL.path, destinationURL.path, flags) == 0 else {
            throw PortError.launchFailed("Could not install the Mac app: " + String(cString: strerror(errno)))
        }
        return destinationURL
    }

    public func cleanup() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) { try FileManager.default.removeItem(at: rootURL) }
    }

    /// After an app crash or forced termination, only reap marked directories
    /// whose owning Studio process no longer exists. Never touch another build.
    public static func removeAbandonedBuilds(in applications: URL) throws {
        let fm = FileManager.default
        for root in try fm.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) {
            guard root.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
                  (try? fm.destinationOfSymbolicLink(atPath: root.path)) == nil,
                  let attributes = try? fm.attributesOfItem(atPath: root.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let data = try? Data(contentsOf: root.appendingPathComponent("owner.json")), data.count < 1024,
                  let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.uid == getuid(), owner.pid > 0 else { continue }
            if kill(owner.pid, 0) == -1 && errno == ESRCH { try fm.removeItem(at: root) }
        }
    }
}
