import Foundation
import XCTest
@testable import PortCore

final class InstalledMacPortsTests: XCTestCase {
    private let title = "0100152000022000"

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nx-installed-ports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(_ root: URL, _ name: String, _ info: [String: Any]) throws {
        let contents = root.appendingPathComponent(name + ".app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testDiscoveryUsesValidatedTitleMetadataWithoutGameFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (name, id) in [("Valid", title), ("Bad", "../elsewhere"), ("Zero", "0000000000000000")] {
            try app(root, name, ["DMTitleID": id, "CFBundleIdentifier": "org.example.fixture", "CFBundleName": name])
        }
        try app(root, "No bundle ID", ["DMTitleID": title, "DMPrimaryHost": true])
        try app(root, ".Hidden", ["DMTitleID": title, "CFBundleIdentifier": "org.example.hidden", "DMPrimaryHost": true])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.app"), withDestinationURL: root.appendingPathComponent("Valid.app"))
        let found = InstalledMacPorts.scan(in: [root], home: root)
        XCTAssertEqual(found.map(\.name), ["Valid"])
        XCTAssertEqual(found.first?.primarySaveURL.path, root.appendingPathComponent("Library/Application Support/nxnative/" + title + "/save").path)
        XCTAssertEqual(found.first?.isPrimaryHost, false)
        XCTAssertNil(found.first?.engine)
    }

    func testDiscoveryReadsLibraryMetadataAcrossFoldersSortedByName() throws {
        let system = try fixture(), user = try fixture()
        defer { try? FileManager.default.removeItem(at: system); try? FileManager.default.removeItem(at: user) }
        try app(system, "Zeta", ["DMTitleID": "0100000000010000", "CFBundleIdentifier": "org.example.zeta", "CFBundleDisplayName": "Zeta Port",
                                 "CFBundleShortVersionString": "1.2.0", "DMPrimaryHost": true, "DMEngine": "0123456789ab-abcdefabcdefabcdefab", "DMEngineTime": 1764000000])
        try app(user, "Alpha", ["DMTitleID": title.lowercased(), "CFBundleIdentifier": "org.example.alpha", "DMPrimaryHost": true])
        let found = InstalledMacPorts.scan(in: [system, user, system.appendingPathComponent("missing")], home: user)
        XCTAssertEqual(found.map(\.name), ["Alpha", "Zeta Port"])   // CFBundleDisplayName, else the folder's name
        XCTAssertEqual(found.map(\.titleID), [title, "0100000000010000"])
        XCTAssertEqual(found.map(\.version), ["", "1.2.0"])
        XCTAssertEqual(found.map(\.isPrimaryHost), [true, true])
        XCTAssertNil(found[0].engine)
        XCTAssertEqual(found[1].engine, PortEngineStamp(revision: "0123456789ab-abcdefabcdefabcdefab", time: 1764000000))
        XCTAssertEqual(NextendoInstalledGames.names(in: [system, user]), [title.lowercased(): "Alpha", "0100000000010000": "Zeta Port"])
    }

    func testLastPlayedComesFromThePortsLogAndOrdersTheLibrary() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let titles = ["Alpha": "0100000000010000", "Beta": "0100000000020000", "Gamma": "0100000000030000", "Delta": "0100000000040000"]
        for (name, id) in titles { try app(root, name, ["DMTitleID": id, "CFBundleIdentifier": "org.example." + name, "DMPrimaryHost": true]) }
        let logs = root.appendingPathComponent("Library/Logs/nxnative")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        for (name, age) in [("Beta", 3600.0), ("Delta", 60.0)] {
            let log = logs.appendingPathComponent(titles[name]! + ".log")
            try Data("launcher: start\n".utf8).write(to: log)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: log.path)
        }
        try Data("old run".utf8).write(to: logs.appendingPathComponent(titles["Gamma"]! + ".prev.log"))   // only the current log counts
        let found = InstalledMacPorts.scan(in: [root], home: root)
        XCTAssertEqual(found.map(\.name), ["Alpha", "Beta", "Delta", "Gamma"])
        XCTAssertEqual(found.first { $0.name == "Delta" }?.lastPlayed, now.addingTimeInterval(-60))
        XCTAssertNil(found.first { $0.name == "Gamma" }?.lastPlayed)
        XCTAssertEqual(InstalledMacPorts.recentlyPlayedFirst(found).map(\.name), ["Delta", "Beta", "Alpha", "Gamma"])   // never played: by name, after the played ones
    }

    func testEngineStampOfAStudioSnapshotAndOfACheckout() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls: [[String]] = []
        let git: (URL, [String]) -> String? = { _, arguments in
            calls.append(arguments)
            switch arguments.first {
            case "rev-parse": return "0123456789ab"
            case "status": return " M dm/host/main.c"
            case "log": return "1764000000"
            default: return nil
            }
        }
        XCTAssertNil(PortEngineStamp.of(repository: root, git: git))   // neither a snapshot nor a checkout: git never runs
        XCTAssertTrue(calls.isEmpty)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(PortEngineStamp.of(repository: root, git: git), PortEngineStamp(revision: "0123456789ab+dirty", time: 1764000000))
        try Data("0123456789ab-abcdefabcdefabcdefab\n".utf8).write(to: root.appendingPathComponent("ENGINE_REVISION"))
        calls.removeAll()
        XCTAssertEqual(PortEngineStamp.of(repository: root, git: git), PortEngineStamp(revision: "0123456789ab-abcdefabcdefabcdefab", time: nil))
        try Data("1764000000\n".utf8).write(to: root.appendingPathComponent("ENGINE_TIME"))
        XCTAssertEqual(PortEngineStamp.of(repository: root, git: git)?.time, 1764000000)
        XCTAssertTrue(calls.isEmpty)   // the snapshot's files win over git
    }

    func testEngineAgeComparesRevisionsThenCommitTimes() {
        let studio = PortEngineStamp(revision: "bbbbbbbbbbbb-1", time: 200)
        XCTAssertEqual(PortEngineAge.of(nil, against: studio), .unstamped)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "x", time: 1), against: nil), .unknown)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "bbbbbbbbbbbb-1", time: 200), against: studio), .current)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "bbbbbbbbbbbb-1", time: nil), against: studio), .current)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "aaaaaaaaaaaa-1", time: 100), against: studio), .older)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "cccccccccccc-1", time: 300), against: studio), .newer)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "bbbbbbbbbbbb-2", time: 200), against: studio), .different)   // same commit, other local changes
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "aaaaaaaaaaaa+dirty", time: nil), against: studio), .different)
        XCTAssertEqual(PortEngineAge.of(PortEngineStamp(revision: "aaaaaaaaaaaa", time: 100), against: PortEngineStamp(revision: "source-1", time: nil)), .different)
    }
}
