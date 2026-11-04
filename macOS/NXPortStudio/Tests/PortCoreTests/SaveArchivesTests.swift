import Foundation
import XCTest
@testable import PortCore

final class SaveArchivesTests: XCTestCase {
    private let title = "0100152000022000"

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nx-save-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func port(_ root: URL) -> InstalledMacPort {
        InstalledMacPort(appURL: root.appendingPathComponent("Fixture.app"), titleID: title,
                         name: "Synthetic fixture", bundleIdentifier: "org.example.save-fixture", stateURL: root.appendingPathComponent("state"))
    }

    private func python(_ source: String, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", source] + arguments
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return data
    }

    private func backup(_ url: URL, titleID: String? = nil, type: Int = 1) throws {
        _ = try python("""
        import sys,zipfile,struct
        meta=bytearray(86)
        struct.pack_into('<IBQ',meta,0,0x56534b4a,1,int(sys.argv[2],16))
        meta[13:29]=bytes(range(16));meta[37]=int(sys.argv[3])
        with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr('userdata.dat',b'synthetic new save')
            z.writestr('.nx_save_meta.bin',meta)
        """, [url.path, titleID ?? title, String(type)])
    }

    func testImportKeepsPreviousTreeAndExportsAStandardJKSVZip() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let item = port(root)
        try FileManager.default.createDirectory(at: item.primarySaveURL, withIntermediateDirectories: true)
        try Data("previous save".utf8).write(to: item.primarySaveURL.appendingPathComponent("old.dat"))
        let incoming = root.appendingPathComponent("incoming.zip"); try backup(incoming)
        let originalZip = try Data(contentsOf: incoming)
        let imported = try SaveArchiveStore.importArchive(from: incoming, into: item, slot: .primary)
        let previous = try XCTUnwrap(imported.backupURL)
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("old.dat")), Data("previous save".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: item.primarySaveURL.path), ["userdata.dat"])
        XCTAssertNil(imported.durabilityWarning)
        XCTAssertEqual(try Data(contentsOf: incoming), originalZip)
        let outgoing = root.appendingPathComponent("outgoing.zip")
        let exported = try SaveArchiveStore.exportArchive(from: item, slot: .primary, to: outgoing)
        XCTAssertEqual(exported.fileCount, 1)
        let data = try python("""
        import sys,zipfile,json
        with zipfile.ZipFile(sys.argv[1]) as z:
            assert z.testzip() is None
            assert z.read('userdata.dat')==b'synthetic new save'
            assert z.read('.nx_save_meta.bin')[13:29]==bytes(range(16))
            print(json.dumps(sorted(z.namelist())))
        """, [outgoing.path])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), [".nx_save_meta.bin", "userdata.dat"])
    }

    func testWrongTitleAndWrongSlotPreserveCurrentSaves() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let item = port(root)
        for directory in [item.primarySaveURL, item.deviceSaveURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: directory.appendingPathComponent("old"))
        }
        let incoming = root.appendingPathComponent("incoming.zip")
        try backup(incoming, titleID: "0100000000000001")
        XCTAssertThrowsError(try SaveArchiveStore.importArchive(from: incoming, into: item, slot: .primary))
        try backup(incoming, type: 3)
        XCTAssertThrowsError(try SaveArchiveStore.importArchive(from: incoming, into: item, slot: .primary))
        XCTAssertEqual(try Data(contentsOf: item.primarySaveURL.appendingPathComponent("old")), Data("keep".utf8))
        _ = try SaveArchiveStore.importArchive(from: incoming, into: item, slot: .device)
        XCTAssertEqual(try Data(contentsOf: item.primarySaveURL.appendingPathComponent("old")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: item.deviceSaveURL.appendingPathComponent("userdata.dat")), Data("synthetic new save".utf8))
    }

    func testDiscoveryUsesValidatedTitleMetadataWithoutGameFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (name, id) in [("Valid", title), ("Bad", "../elsewhere"), ("Zero", "0000000000000000")] {
            let contents = root.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["DMTitleID": id, "CFBundleIdentifier": "org.example.fixture", "CFBundleName": name]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let found = SaveArchiveStore.installedPorts(in: [root], home: root)
        XCTAssertEqual(found.map(\.name), ["Valid"])
        XCTAssertEqual(found.first?.primarySaveURL.path, root.appendingPathComponent("Library/Application Support/nxnative/" + title + "/save").path)
    }
}
