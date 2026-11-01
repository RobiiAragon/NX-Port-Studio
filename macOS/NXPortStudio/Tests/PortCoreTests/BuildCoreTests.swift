import XCTest
@testable import PortCore

final class BuildCoreTests: XCTestCase {
    private func fixture() throws -> (URL, BuildConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Port tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("engine/scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Bowser's game"), withIntermediateDirectories: true)
        try Data("# synthetic script\n".utf8).write(to: root.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py"))
        try Data().write(to: root.appendingPathComponent("Bowser's game/Test.nsp"))
        try Data("synthetic fixture, not console keys".utf8).write(to: root.appendingPathComponent("prod.keys"))
        let config = BuildConfiguration(repositoryURL: root.appendingPathComponent("engine"),
                                        gameDirectoryURL: root.appendingPathComponent("Bowser's game"),
                                        keysURL: root.appendingPathComponent("prod.keys"),
                                        outputURL: root.appendingPathComponent("Test.app"), destination: .macOS)
        return (root, config)
    }

    func testBuildArgumentsPreservePathsAndUseJSON() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL)
        XCTAssertTrue(command.arguments.contains(config.gameDirectoryURL.path))
        XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--platform")! + 1], "mac-app")
        XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--progress")! + 1], "json")
        XCTAssertFalse(command.redactedDescription.contains(config.keysURL.path))
    }

    func testExistingPortIsNotOverwritten() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: config.outputURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
    }

    func testArchiveOnlyGameFolderCanStartBuildPreparation() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: config.gameDirectoryURL.appendingPathComponent("Test.nsp"))
        let archive = config.gameDirectoryURL.appendingPathComponent("Base Game.7Z")
        try Data("synthetic archive input".utf8).write(to: archive)
        let summary = try GameFolderSummary.inspect(config.gameDirectoryURL)
        XCTAssertEqual(summary.files.map(\.lastPathComponent), [archive.lastPathComponent])
        XCTAssertTrue(summary.containsArchives)
        XCTAssertEqual(summary.byteCount, 23)
        XCTAssertNoThrow(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
    }

    func testNestedGameInputsUseCaseInsensitiveExtensionsAndStableOrder() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: config.gameDirectoryURL.appendingPathComponent("Test.nsp"))
        let paths = ["Updates/Update.NSP", "Base/Game.XCI", "Extras/DLC.NsZ", "Extras/Other.XcZ", "Packed/Bundle.ZIP", "Packed/Base.7z"]
        for path in paths {
            let file = config.gameDirectoryURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let summary = try GameFolderSummary.inspect(config.gameDirectoryURL)
        XCTAssertEqual(summary.files.map { $0.pathComponents.suffix(2).joined(separator: "/") }, paths.sorted())
        XCTAssertEqual(summary.byteCount, Int64(paths.count * 7))
        XCTAssertTrue(summary.containsArchives)
    }

    func testSummaryExcludesHiddenGeneratedPackagesAndDirectoriesBeyondDepthLimit() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: config.gameDirectoryURL.appendingPathComponent("Test.nsp"))
        let kept = "One/Two/Three/Four/Depth Four.nsp"
        let excluded = [".nx-archives/cache.nsp", ".hidden.nsp", "Title_build/extracted.nsp", "Title-WORK/extracted.nsp", "Title_SURVEY/extracted.nsp",
                        "Title.app/Contents/Resources/game.nsp", "Images.xcassets/game.zip", "Build.xcodeproj/game.xci", "One/Two/Three/Four/Five/Too Deep.nsp"]
        for path in [kept] + excluded {
            let file = config.gameDirectoryURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let summary = try GameFolderSummary.inspect(config.gameDirectoryURL)
        XCTAssertEqual(summary.files.map(\.lastPathComponent), ["Depth Four.nsp"])
        XCTAssertEqual(summary.byteCount, 7)
        XCTAssertFalse(summary.containsArchives)
    }

    func testSummaryDoesNotFollowFileDirectoryOrRootSymlinks() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: config.gameDirectoryURL.appendingPathComponent("Test.nsp"))
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = outside.appendingPathComponent("Actual.nsp")
        try Data("fixture".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: config.gameDirectoryURL.appendingPathComponent("Linked.nsp"), withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: config.gameDirectoryURL.appendingPathComponent("Linked Folder"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: config.gameDirectoryURL.appendingPathComponent("Dangling.zip"), withDestinationURL: outside.appendingPathComponent("Missing.zip"))
        XCTAssertTrue(try GameFolderSummary.inspect(config.gameDirectoryURL).files.isEmpty)
        let linkedRoot = root.appendingPathComponent("Linked Root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        XCTAssertTrue(try GameFolderSummary.inspect(linkedRoot).files.isEmpty)
    }

    func testDirectoryMasqueradingAsGameAndEmptyKeysAreRejected() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: original.gameDirectoryURL.appendingPathComponent("Test.nsp"))
        try FileManager.default.createDirectory(at: original.gameDirectoryURL.appendingPathComponent("Fake.nsp"), withIntermediateDirectories: false)
        XCTAssertTrue(try GameFolderSummary.inspect(original.gameDirectoryURL).files.isEmpty)
        XCTAssertThrowsError(try BuildCommand.make(configuration: original, pythonURL: ToolEnvironment.defaultPythonURL))
        try Data().write(to: original.gameDirectoryURL.appendingPathComponent("Real.nsp"))
        try Data().write(to: original.keysURL)
        XCTAssertThrowsError(try BuildCommand.make(configuration: original, pythonURL: ToolEnvironment.defaultPythonURL))
        try FileManager.default.removeItem(at: original.keysURL)
        try FileManager.default.createDirectory(at: original.keysURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try BuildCommand.make(configuration: original, pythonURL: ToolEnvironment.defaultPythonURL))
    }

    func testDanglingOutputSymlinkIsRejected() throws {
        let (root, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: config.outputURL, withDestinationURL: root.appendingPathComponent("elsewhere.app"))
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
    }

    func testIOSPreparationKeepsXcodeAssetsInGameFolder() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = original
        config.destination = .iOS; config.prepareXcode = true; config.teamID = "SYNTHETIC1"
        config.outputURL = root.appendingPathComponent("Test.ipa")
        let command = try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL)
        XCTAssertTrue(command.arguments.contains("--prepare-xcode"))
        XCTAssertTrue(command.arguments.contains(config.gameDirectoryURL.appendingPathComponent("NXPortStudio.xcworkspace").path))
        XCTAssertTrue(command.arguments.contains("--keep-extracted"))
        XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--team-id")! + 1], "SYNTHETIC1")
    }

    func testIOSAlwaysPreparesSigningEvenWhenLegacyFlagIsOff() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = original
        config.destination = .iOS; config.prepareXcode = false; config.teamID = " abcdefgh12 "
        config.outputURL = root.appendingPathComponent("Signed.ipa")
        let command = try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL)
        XCTAssertTrue(command.arguments.contains("--prepare-xcode"))
        XCTAssertFalse(command.arguments.contains("-o"), "The unsigned IPA packing path must never run for Studio iOS builds")
        XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--team-id")! + 1], "ABCDEFGH12")
    }

    func testIOSRequiresValidTeamBeforePreparing() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = original
        config.destination = .iOS; config.outputURL = root.appendingPathComponent("Signed.ipa")
        for invalidTeam in [nil, "", "SYNTHETIC", "ABCDE-FG12"] as [String?] {
            config.teamID = invalidTeam
            XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
        }
    }

    func testIOSPublicOAuthClientIsPassedOnlyThroughBuildEnvironment() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = original
        config.destination = .iOS; config.teamID = "SYNTHETIC1"
        config.outputURL = root.appendingPathComponent("Signed.ipa")
        let clientID = "nxc_" + "fixture_port"
        config.nextendoClientID = " \(clientID) "
        let command = try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL)
        XCTAssertEqual(command.environment["DM_NEXTENDO_CLIENT_ID"], clientID)
        XCTAssertFalse(command.arguments.contains { $0.contains(clientID) })
        XCTAssertFalse(command.redactedDescription.contains(clientID))
        config.nextendoClientID = "unregistered\ninvalid"
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
        config.nextendoClientID = nil
        XCTAssertNil(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL).environment["DM_NEXTENDO_CLIENT_ID"])
    }

    func testIOSPreparationRejectsExistingIPAAndInvalidExportPaths() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = original
        config.destination = .iOS; config.prepareXcode = true; config.teamID = "ABCDEFGH12"
        config.outputURL = root.appendingPathComponent("Existing.ipa")
        try Data("existing export".utf8).write(to: config.outputURL)
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
        XCTAssertEqual(try String(contentsOf: config.outputURL, encoding: .utf8), "existing export")
        config.outputURL = root.appendingPathComponent("missing-parent/Signed.ipa")
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
        config.outputURL = root.appendingPathComponent("Wrong.app")
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
        config.outputURL = root.appendingPathComponent("Dangling.ipa")
        try FileManager.default.createSymbolicLink(at: config.outputURL, withDestinationURL: root.appendingPathComponent("elsewhere.ipa"))
        XCTAssertThrowsError(try BuildCommand.make(configuration: config, pythonURL: ToolEnvironment.defaultPythonURL))
    }

    func testStructuredProgressHandlesUnknownAndNullFields() {
        let event = ProgressEvent.decode(line: #"{"ev":"progress","name":"shaders","k":3,"n":7,"frac":0.42,"done":42,"total":100,"eta":null,"future_field":"ignored"}"#)
        XCTAssertEqual(event?.stageName, "shaders")
        XCTAssertEqual(event?.fraction, 0.42)
        XCTAssertNil(event?.eta)
        XCTAssertNil(ProgressEvent.decode(line: "ordinary stderr"))
    }

    func testKeyMaterialRedactedFromLogs() {
        XCTAssertEqual(LogRedactor.clean("master_key_00 = 0123456789abcdef0123456789abcdef"), "master_key_00 = [redacted]")
        XCTAssertEqual(LogRedactor.clean("main build 0123456789abcdef"), "main build 0123456789abcdef")
    }

    func testRunnerDoesNotInterpretArgumentsAsShellCode() async throws {
        let literal = "a path's name; $(echo unsafe) `echo unsafe`"
        let command = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s\\n", literal])
        let result = try await ProcessRunner().run(command)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, literal + "\n")
    }

    func testRunnerSurfacesNonzeroExitAndStderr() async throws {
        let command = ProcessCommand(executableURL: ToolEnvironment.defaultPythonURL,
                                     arguments: ["-c", "import sys; print('diagnostic', file=sys.stderr); sys.exit(7)"])
        let result = try await ProcessRunner().run(command)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.output.contains("diagnostic"))
    }

    func testCancellationStopsDescendantsThatIgnoreTerminate() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("port-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let ready = expectation(description: "child ready")
        let runner = ProcessRunner()
        let child = "import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('child-ready',flush=True); time.sleep(2.5); pathlib.Path(\(String(reflecting: marker.path))).touch()"
        let parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-u','-c',sys.argv[1]]); time.sleep(30)"
        let task = Task {
            try await runner.run(ProcessCommand(executableURL: ToolEnvironment.defaultPythonURL,
                                                 arguments: ["-u", "-c", parent, child])) { line in
                if line == "child-ready" { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        runner.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await Task.sleep(for: .seconds(1.3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A cancelled descendant must never complete its write")
    }

    func testCancellationStopsDescendantsWithRedirectedOutput() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("port-detached-\(UUID().uuidString)")
        let readyFile = marker.appendingPathExtension("ready")
        defer { try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: readyFile) }
        let ready = expectation(description: "redirected child ready")
        let runner = ProcessRunner()
        let child = "import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(\(String(reflecting: readyFile.path))).touch(); time.sleep(2); pathlib.Path(\(String(reflecting: marker.path))).touch()"
        let parent = "import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-u','-c',sys.argv[1]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); p=pathlib.Path(sys.argv[2]);\nwhile not p.exists(): time.sleep(.01)\nprint('ready',flush=True); time.sleep(30)"
        let task = Task {
            try await runner.run(ProcessCommand(executableURL: ToolEnvironment.defaultPythonURL,
                                                 arguments: ["-u", "-c", parent, child, readyFile.path])) { line in
                if line == "ready" { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        runner.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await Task.sleep(for: .seconds(2.3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let next = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["reused"]))
        XCTAssertEqual(next.output, "reused\n", "The same runner must work after cancellation")
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let runner = ProcessRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["must not run"]))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testImmediateCancellationNeedsNoDelayedEscalation() async throws {
        let ready = expectation(description: "process ready")
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(ProcessCommand(executableURL: ToolEnvironment.defaultPythonURL,
                                                 arguments: ["-u", "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(30)"])) { line in
                if line == "ready" { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        let start = ContinuousClock.now
        runner.cancelImmediately()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
}
