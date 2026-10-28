import Foundation
import CryptoKit

public struct FirmwareCatalog: Codable, Equatable, Sendable {
    public struct ImportedFile: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }
    public struct Resource: Codable, Equatable, Sendable, Identifiable {
        public let titleId: String
        public let name: String
        public let relativePath: String
        public let contentSha256: String
        public let bytes: Int64
        public let files: [ImportedFile]
        public var id: String { titleId }
    }
    public let formatVersion: Int
    public let firmwareVersion: String
    public let contentDigest: String
    public let importedAt: String
    public let sourceKind: String
    public let archiveCount: Int
    public let resources: [Resource]
    public var resourceBytes: Int64 { resources.reduce(0) { $0 + $1.bytes } }
}

public struct ImportedFirmware: Equatable, Sendable, Identifiable {
    public let catalog: FirmwareCatalog
    public let directoryURL: URL
    public var id: String { directoryURL.path }
    public var systemDataURL: URL { directoryURL.appendingPathComponent("system_data", isDirectory: true) }
}

public enum FirmwareLibrary {
    public static var ryujinxSourceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ryujinx/bis/system/Contents/registered", isDirectory: true)
    }

    public static func load(at directory: URL, verifyHashes: Bool = false) throws -> ImportedFirmware {
        let catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard catalog.formatVersion == 1,
              catalog.firmwareVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              catalog.contentDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              catalog.archiveCount > 0, !catalog.resources.isEmpty else { throw PortError.invalidConfiguration("The firmware resource catalog is invalid.") }
        let root = directory.resolvingSymlinksInPath().path + "/"
        for resource in catalog.resources {
            guard resource.titleId.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
                  resource.relativePath == "system_data/\(resource.titleId)/files", resource.bytes > 0, !resource.files.isEmpty,
                  resource.bytes == resource.files.reduce(0, { $0 + $1.bytes }) else {
                throw PortError.invalidConfiguration("The firmware resource catalog contains an invalid archive.")
            }
            for file in resource.files {
                let url = directory.appendingPathComponent(resource.relativePath).appendingPathComponent(file.path)
                guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                      url.resolvingSymlinksInPath().path.hasPrefix(root), file.bytes >= 0,
                      file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
                      Int64(info.fileSize ?? -1) == file.bytes else { throw PortError.invalidConfiguration("Imported firmware resources are missing or incomplete. Import the dump again.") }
                if verifyHashes {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hash = SHA256()
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard actual == file.sha256 else { throw PortError.invalidConfiguration("Imported firmware resources failed their content hash check. Import the dump again.") }
                }
            }
        }
        return ImportedFirmware(catalog: catalog, directoryURL: directory)
    }

    public static func installed(in library: URL) -> [ImportedFirmware] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { try? load(at: $0) }.sorted { $0.catalog.importedAt > $1.catalog.importedAt }
    }

    public static func importResources(sourceURL: URL, keysURL: URL, repositoryURL: URL, libraryURL: URL,
                                       toolsURL: URL, using runner: ProcessRunner,
                                       onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> ImportedFirmware {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: keysURL.path),
              (try? keysURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PortError.invalidConfiguration("Select prod.keys from your console before importing firmware.")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue || sourceURL.pathExtension.lowercased() == "zip" else {
            throw PortError.invalidConfiguration("Choose a firmware directory or ZIP file.")
        }
        guard let dotnet = ToolEnvironment.executable(named: "dotnet") else {
            throw PortError.invalidConfiguration("Prepare the environment to install .NET before importing firmware.")
        }
        let sourceFolder = repositoryURL.appendingPathComponent("dm/tools/nx_extract", isDirectory: true)
        let files = ["nx_extract.csproj", "Program.cs", "FirmwareResources.cs", "FriendsPlayHistoryResources.cs"]
        var digest = SHA256()
        for file in files { digest.update(data: try Data(contentsOf: sourceFolder.appendingPathComponent(file))) }
        let revision = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let tool = toolsURL.appendingPathComponent("firmware-extractor-" + revision.prefix(16), isDirectory: true)
        let dll = tool.appendingPathComponent("bin/nx_extract.dll")
        let ready = tool.appendingPathComponent("ready")
        if !fm.fileExists(atPath: dll.path) || (try? String(contentsOf: ready, encoding: .utf8)) != revision {
            let project = tool.appendingPathComponent("source", isDirectory: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            for file in files {
                let destination = project.appendingPathComponent(file)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: sourceFolder.appendingPathComponent(file), to: destination)
            }
            onLine("Preparing the firmware resource extractor…")
            let command = ProcessCommand(executableURL: dotnet, arguments: ["publish", project.appendingPathComponent("nx_extract.csproj").path,
                "-c", "Release", "--output", tool.appendingPathComponent("bin").path, "--no-self-contained"],
                environment: ToolEnvironment.values, redactedDescription: "Build the local firmware resource extractor")
            let result = try await runner.run(command, onLine: onLine)
            guard result.exitCode == 0 else { throw PortError.processFailed(result.exitCode, "The firmware extractor could not be built. Review Activity.") }
            try Task.checkCancellation()
            try revision.write(to: ready, atomically: true, encoding: .utf8)
        }
        try Task.checkCancellation()
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let temporary = libraryURL.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        let command = ProcessCommand(executableURL: dotnet, arguments: [dll.path, keysURL.path, "--firmware", sourceURL.path, temporary.path],
            environment: ToolEnvironment.values, redactedDescription: "Validate and extract local firmware resources — keys hidden")
        let result = try await runner.run(command, onLine: onLine)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw PortError.processFailed(result.exitCode, "Firmware import failed. Review Activity; prod.keys must support the firmware version you selected.")
        }
        let imported = try load(at: temporary, verifyHashes: true)
        let destination = libraryURL.appendingPathComponent(imported.catalog.firmwareVersion + "-" + imported.catalog.contentDigest.prefix(16), isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            let existing = try load(at: destination, verifyHashes: true)
            guard existing.catalog.contentDigest == imported.catalog.contentDigest else { throw PortError.invalidConfiguration("The existing firmware catalog conflicts with this import.") }
            onLine("The same validated firmware resources are already imported.")
            return existing
        }
        try fm.moveItem(at: temporary, to: destination)
        return try load(at: destination)
    }
}
