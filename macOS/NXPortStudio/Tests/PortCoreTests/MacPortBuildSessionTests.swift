import XCTest
import Darwin
@testable import PortCore

final class MacPortBuildSessionTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func app(at url: URL, title: String = "0100000000000000", signed: Bool = true) async throws {
        let fm = FileManager.default
        let mac = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: mac, withIntermediateDirectories: true)
        // A synthetic, unrelated system executable; no game or console files.
        for name in ["dmhost", "launcher"] { try fm.copyItem(atPath: "/usr/bin/true", toPath: mac.appendingPathComponent(name).path) }
        let info = ["CFBundleIdentifier": "org.nxnative.tests.game", "CFBundleExecutable": "launcher",
                    "CFBundlePackageType": "APPL", "DMTitleID": title]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        if signed {
            let result = try await ProcessRunner().run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--deep", "--sign", "-", url.path]))
            XCTAssertEqual(result.exitCode, 0, result.output)
        }
    }

    func testInstallAndAtomicUpdateRemoveAllScratchFiles() async throws {
        let parent = try fixture(), target = parent.appendingPathComponent("Game.app")
        for _ in 0..<2 {
            let session = try MacPortBuildSession(destinationURL: target)
            try await app(at: session.applicationURL)
            try Data("intermediate".utf8).write(to: session.workURL.appendingPathComponent("temporary.bin"))
            let installed = try await session.install(using: ProcessRunner())
            XCTAssertEqual(installed.path, target.path)
            try session.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.rootURL.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Game.app"])
        }
    }

    func testEngineGenerationCannotLeaveFilesInSourceCheckout() async throws {
        let parent = try fixture(), repository = parent.appendingPathComponent("source")
        let fm = FileManager.default
        for name in ["dm/tools", "dm/host/gen", "scripts", "dm/tools/obj"] {
            try fm.createDirectory(at: repository.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["dm/tools/tool.py", "scripts/build.py", "dm/host/gen/old.h", "dm/tools/obj/old.o"] {
            try Data("fixture".utf8).write(to: repository.appendingPathComponent(name))
        }
        let session = try MacPortBuildSession(destinationURL: parent.appendingPathComponent("Game.app"))
        try await session.prepareEngine(from: repository, using: ProcessRunner())
        XCTAssertTrue(fm.fileExists(atPath: session.engineURL.appendingPathComponent("dm/tools/tool.py").path))
        XCTAssertFalse(fm.fileExists(atPath: session.engineURL.appendingPathComponent("dm/host/gen/old.h").path))
        XCTAssertFalse(fm.fileExists(atPath: session.engineURL.appendingPathComponent("dm/tools/obj/old.o").path))
        try Data("generated".utf8).write(to: session.engineURL.appendingPathComponent("dm/tools/generated.bin"))
        try session.cleanup()
        XCTAssertFalse(fm.fileExists(atPath: repository.appendingPathComponent("dm/tools/generated.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: repository.appendingPathComponent("dm/host/gen/old.h").path))
    }

    func testInvalidSignatureAndDifferentTitlePreserveInstalledApp() async throws {
        let parent = try fixture(), target = parent.appendingPathComponent("Game.app")
        try await app(at: target)
        let original = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        for signed in [false, true] {
            let session = try MacPortBuildSession(destinationURL: target)
            defer { try? session.cleanup() }
            try await app(at: session.applicationURL, title: "0100000000000001", signed: signed)
            do { _ = try await session.install(using: ProcessRunner()); XCTFail("Invalid update was accepted") }
            catch { /* Expected: no installed file is changed. */ }
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), original)
        }
    }

    func testCancellationCleansIntermediatesAfterProcessGroupExits() async throws {
        let parent = try fixture()
        let session = try MacPortBuildSession(destinationURL: parent.appendingPathComponent("Game.app"))
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "touch \"$1/started\"; exec sleep 30", "fixture", session.workURL.path]))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: session.workURL.appendingPathComponent("started").path) {
            guard ContinuousClock.now < deadline else { task.cancel(); XCTFail("Process did not start"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process succeeded") } catch is CancellationError { }
        try session.cleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testRejectsUnrelatedAppAndSymlinkWithoutDeletingThem() throws {
        let parent = try fixture(), unrelated = parent.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MacPortBuildSession(destinationURL: unrelated))
        let link = parent.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        XCTAssertThrowsError(try MacPortBuildSession(destinationURL: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCrashRecoveryRemovesOnlyMarkedBuildWhoseOwnerExited() throws {
        let parent = try fixture()
        let session = try MacPortBuildSession(destinationURL: parent.appendingPathComponent("Game.app"))
        try MacPortBuildSession.removeAbandonedBuilds(in: parent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.rootURL.path), "Live builds must remain")
        let unmarked = parent.appendingPathComponent(".nx-port-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        let owner = ["pid": Int32.max, "uid": Int32(getuid())]
        try JSONSerialization.data(withJSONObject: owner).write(to: session.rootURL.appendingPathComponent("owner.json"))
        try MacPortBuildSession.removeAbandonedBuilds(in: parent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path))
    }
}
