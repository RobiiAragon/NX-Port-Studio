import Foundation

public struct MiiLibrarySummary: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
    }
    public let schema: Int
    public let count: Int
    public let imported: Int
    public let updated: Int
    public let duplicates: Int
    public let entries: [Entry]

    public static let empty = MiiLibrarySummary(schema: 1, count: 0, imported: 0, updated: 0, duplicates: 0, entries: [])
}

/// The runtime's C validator also validates Studio imports. Personal records
/// stay local; stdout is decoded here and never forwarded to the activity log.
public enum MiiLibrary {
    public static func load(databaseURL: URL, repositoryURL: URL, pythonURL: URL,
                            using runner: ProcessRunner) async throws -> MiiLibrarySummary {
        try await run(arguments: ["list", "--database", databaseURL.path],
                      repositoryURL: repositoryURL, pythonURL: pythonURL, using: runner)
    }

    public static func importRecords(from sourceURL: URL, databaseURL: URL,
                                     repositoryURL: URL, pythonURL: URL,
                                     using runner: ProcessRunner) async throws -> MiiLibrarySummary {
        try await run(arguments: ["import", "--database", databaseURL.path, "--source", sourceURL.path],
                      repositoryURL: repositoryURL, pythonURL: pythonURL, using: runner)
    }

    private static func run(arguments: [String], repositoryURL: URL, pythonURL: URL,
                             using runner: ProcessRunner) async throws -> MiiLibrarySummary {
        let script = repositoryURL.appendingPathComponent("scripts/import_miis.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw PortError.invalidConfiguration("The engine does not include the personal Mii importer. Update Studio first.")
        }
        let command = ProcessCommand(executableURL: pythonURL, arguments: [script.path] + arguments,
            workingDirectoryURL: repositoryURL, environment: ToolEnvironment.values,
            redactedDescription: "Validate local personal Miis")
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            // The validator's structured code is useful without retaining names
            // or binary records from its private output in the public build log.
            let error = try? JSONDecoder().decode(ImportFailure.self, from: Data(result.output.utf8))
            throw PortError.invalidConfiguration(error?.error.message ?? "The personal Mii data could not be validated.")
        }
        let summary = try JSONDecoder().decode(MiiLibrarySummary.self, from: Data(result.output.utf8))
        guard summary.schema == 1, (0...100).contains(summary.count), summary.entries.count == summary.count,
              Set(summary.entries.map(\.id)).count == summary.count else {
            throw PortError.invalidConfiguration("The personal Mii importer returned an invalid result.")
        }
        return summary
    }

    private struct ImportFailure: Decodable {
        struct Detail: Decodable { let code: String; let message: String }
        let error: Detail
    }
}
