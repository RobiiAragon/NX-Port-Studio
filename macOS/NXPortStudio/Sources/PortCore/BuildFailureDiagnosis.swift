import Foundation

/// A next step for a known build failure. The original log stays in Activity;
/// these fixed messages never copy paths, key values or arbitrary tool output
/// into an alert. Unknown failures deliberately keep the ordinary log guidance.
public struct BuildFailureDiagnosis: Equatable, Sendable {
    public enum Category: String, Sendable {
        case missingBase, unreadableInput, conflictingInputs, archive
        case missingKeys, incompatibleKeys, damagedDump, storage
        case unsupportedProgram, dependency
    }

    public let category: Category
    public var title: String {
        switch category {
        case .missingBase: "The base game is missing."
        case .unreadableInput: "The game files could not be identified."
        case .conflictingInputs: "The folder contains conflicting games."
        case .archive: "The game archive could not be prepared."
        case .missingKeys: "The console keys file is unavailable."
        case .incompatibleKeys: "Required console keys are missing."
        case .damagedDump: "The game dump is incomplete or damaged."
        case .storage: "There is not enough free disk space."
        case .unsupportedProgram: "This program cannot run on the selected platform."
        case .dependency: "A required build tool is unavailable."
        }
    }
    public var recovery: String {
        switch category {
        case .missingBase:
            "Add the complete base game dump alongside its update or DLC. ZIP and 7z archives are unpacked automatically."
        case .unreadableInput:
            "Select a complete NSP, XCI, NSZ or XCZ dump, or a ZIP or 7z archive containing one. Check Activity for the exact file."
        case .conflictingInputs:
            "Keep one base dump and only that game's updates and DLC in the selected folder. Move other games or duplicate bases to another folder."
        case .archive:
            "Check that the archive finished copying. Extract encrypted, nested or unsupported archives beside the update, then select that folder again. The original archive is retained."
        case .missingKeys:
            "Select a readable, nonempty prod.keys file dumped from your own console."
        case .incompatibleKeys:
            "Select updated prod.keys dumped from your own console that support this game and its update. Key values must stay private."
        case .damagedDump:
            "Copy a complete dump from your own console again, then retry. Check Activity for the failed file or integrity check."
        case .storage:
            "Free space on the volume containing the game and build folder, then retry. Check Activity for the required amount."
        case .unsupportedProgram:
            "Native ports require a 64-bit ARM game and an Apple silicon Mac. Check Activity for the unsupported program or host."
        case .dependency:
            "Open Environment, check the selected destination's requirements and prepare the missing tools. Check Activity for the exact dependency."
        }
    }

    /// Search bounded log records, decoding the actual JSON progress schema as
    /// well as plain stderr. A known final [RED] cause wins over earlier
    /// messages; a wrapper such as "nx_extract exit code 3" does not conceal
    /// the specific integrity or key error that preceded it.
    public static func classify(output: String) -> Self? {
        let tail = String(decoding: output.utf8.suffix(1_048_576), as: UTF8.self)
        let records = tail.split(whereSeparator: \.isNewline).suffix(2_048).compactMap { raw -> String? in
            guard raw.utf8.count <= 65_536 else { return nil }
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("{") {
                guard let event = ProgressEvent.decode(line: line) else { return nil }
                // Progress names and counters are not error messages.
                if event.ev == "say" { return event.msg }
                if event.ev == "stage_end", event.ok == false { return event.summary }
                return nil
            }
            return line
        }
        for redOnly in [true, false] {
            for record in records.reversed() {
                let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                let red = trimmed.hasPrefix("[RED] ")
                guard red == redOnly else { continue }
                let message = red ? String(trimmed.dropFirst(6)) : trimmed
                if let category = category(for: message) { return Self(category: category) }
            }
        }
        return nil
    }

    private static func category(for message: String) -> Category? {
        // Patterns correspond to emitted tool errors, not guesses based on a
        // file extension or words such as "key" anywhere in a compiler log.
        let rows: [(Category, String)] = [
            (.storage, #"\bNo space left on device\b|^less than [0-9]+(?:\.[0-9]+)? GB free on the volume\b|^not enough free disk space to extract\b"#),
            (.missingBase, #"^no base game(?: NSP)? found\b"#),
            (.conflictingInputs, #"^more than one (?:base game|game)(?: for| in|:)"#),
            (.damagedDump, #"^(?:truncated|invalid) PFS0 (?:header|metadata|filename table)\b|\bfiles fail the NCA's hash check\b|^hash check failed:"#),
            (.missingKeys, #"^no such file: "#),
            (.incompatibleKeys, #"\bMissingKeyException\b|\bUnable to decrypt (?:the )?NCA header\b"#),
            (.unsupportedProgram, #"\bis a 32-bit ARM program\b|\bneeds a Mac with Apple silicon\b"#),
            (.dependency, #"^(?:tools not found:|dotnet not found\b|the current Python .+ is missing modules:|the Metal compiler does not run\b|the shader translator is missing\b|NSZ / XCZ files need the nsz tool\b|ZIP / 7z game archives require libarchive\b|the installed libarchive lacks\b)"#),
            (.archive, #"^archive (?:contains|member|has|exceeds|cache|changed)\b|^could not allocate the archive reader\b|Encrypted or damaged archives must be extracted manually|^no NSP, XCI, NSZ or XCZ inside\b|^the generated \.nx-archives directory must not be a symbolic link\b"#),
            (.unreadableInput, #"^no (?:NSP|game input) with a readable title ID\b|^invalid game metadata\b|^could not identify .+ from its game metadata\b|^game metadata disagrees\b"#),
        ]
        return rows.first { message.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }?.0
    }
}
