import XCTest
@testable import PortCore

final class BuildFailureDiagnosisTests: XCTestCase {
    private func say(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["ev": "say", "msg": text]), as: UTF8.self)
    }

    func testOriginalAndUpdatedMissingBaseMessagesHaveActionableDiagnosis() throws {
        for message in [
            "[RED] no base game NSP found in /private/game (title ID 0100000000010000)",
            "[RED] no base game found in /private/game (title ID 0100000000010000); an update or DLC alone cannot build a game."
        ] {
            let diagnosis = BuildFailureDiagnosis.classify(output: try say(message))
            XCTAssertEqual(diagnosis?.category, .missingBase)
            XCTAssertFalse(diagnosis?.title.contains("/private") ?? true)
            XCTAssertFalse(diagnosis?.recovery.contains("/private") ?? true)
        }
    }

    func testKnownCausesAreDistinct() {
        let cases: [(String, BuildFailureDiagnosis.Category)] = [
            ("no game input with a readable title ID in /private/game", .unreadableInput),
            ("no NSP with a readable title ID in /private/game", .unreadableInput),
            ("invalid game metadata for Unknown.xci: container holds multiple content records", .unreadableInput),
            ("could not identify Unknown.xci from its game metadata; check the complete dump and console keys", .unreadableInput),
            ("game metadata disagrees with the ticket or title tag in Update.nsp; check the complete dump", .unreadableInput),
            ("more than one game in the folder, keep one game per folder: 0100000000010000", .conflictingInputs),
            ("more than one base game for 0100000000010000: duplicate dumps", .conflictingInputs),
            ("archive contains an unsafe path; extract a clean game dump manually", .archive),
            ("archive member is truncated", .archive),
            ("cannot read test.7z: error. Encrypted or damaged archives must be extracted manually", .archive),
            ("no NSP, XCI, NSZ or XCZ inside test.zip; extract nested archives manually", .archive),
            ("no such file: /private/my-own.keys", .missingKeys),
            ("LibHac.Common.Keys.MissingKeyException: a required key is missing", .incompatibleKeys),
            ("Unable to decrypt the NCA header", .incompatibleKeys),
            ("invalid PFS0 metadata in test.nsp; copy the complete game dump and retry", .damagedDump),
            ("hash check failed: /some/game/file", .damagedDump),
            ("4 files fail the NCA's hash check (an incomplete copy)", .damagedDump),
            ("less than 40 GB free on the volume of /private/build", .storage),
            ("OSError: [Errno 28] No space left on device", .storage),
            ("not enough free disk space to extract this game archive (256 MiB reserve required)", .storage),
            ("Test Game (0100000000010000) is a 32-bit ARM program", .unsupportedProgram),
            ("it needs a Mac with Apple silicon, and this Mac has an Intel processor", .unsupportedProgram),
            ("tools not found: dotnet (.NET SDK 10)", .dependency),
            ("the current Python (/private/python) is missing modules: capstone", .dependency),
            ("NSZ / XCZ files need the nsz tool in the current Python", .dependency),
            ("ZIP / 7z game archives require libarchive; extract the archive beside your update NSP and retry", .dependency),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(BuildFailureDiagnosis.classify(output: "[RED] " + message)?.category, expected, message)
        }
    }

    func testLatestKnownRedCauseWinsOverEarlierFailure() throws {
        let output = [
            try say("[RED] no base game NSP found in /private/old"),
            try say("imported firmware resources: 10 archives"),
            try say("[RED] tools not found: zstd"),
            "Process exited with status 1."
        ].joined(separator: "\n")
        XCTAssertEqual(BuildFailureDiagnosis.classify(output: output)?.category, .dependency)
    }

    func testWrapperDoesNotHideActualExtractionIntegrityFailure() throws {
        let output = ["[RED] 3 files fail the NCA's hash check", try say("[RED] nx_extract exit code 3 (full output: /private/log)")].joined(separator: "\n")
        XCTAssertEqual(BuildFailureDiagnosis.classify(output: output)?.category, .damagedDump)
    }

    func testDecodesFailedStageButIgnoresNonmessageFields() throws {
        let failed = String(decoding: try JSONSerialization.data(withJSONObject: ["ev": "stage_end", "ok": false, "summary": "No space left on device"]), as: UTF8.self)
        XCTAssertEqual(BuildFailureDiagnosis.classify(output: failed)?.category, .storage)
        for event in [
            ["ev": "stage", "name": "[RED] no base game found in /fake"],
            ["ev": "stage_end", "ok": true, "summary": "No space left on device"],
            ["ev": "unknown", "msg": "[RED] no such file: /fake"]
        ] as [[String: Any]] {
            let output = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            XCTAssertNil(BuildFailureDiagnosis.classify(output: output))
        }
    }

    func testUnknownAndAmbiguousMessagesDoNotInventCause() {
        for output in ["", "Process exited with status 1.", "[RED] nx_extract exit code 1", "error: key window was not found", "[RED] invalid NCA header", "[RED] no game icon in the extraction", "[RED] provisional game profile: the game may not boot"] {
            XCTAssertNil(BuildFailureDiagnosis.classify(output: output), output)
        }
    }

    func testBoundsSkipOversizedRecordsAndKeepRecentCause() throws {
        let oversized = String(repeating: "x", count: 1_100_000)
        let output = oversized + "\n" + (try say("[RED] no base game found in /private/game"))
        XCTAssertEqual(BuildFailureDiagnosis.classify(output: output)?.category, .missingBase)
        XCTAssertNil(BuildFailureDiagnosis.classify(output: "[RED] no such file: " + String(repeating: "x", count: 70_000)))
    }
}
