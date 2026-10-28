import XCTest
import CryptoKit
@testable import PortCore

final class FirmwareLibraryTests: XCTestCase {
    private func fixture() throws -> (URL, [String: Any]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nx-firmware-test-" + UUID().uuidString)
        let folder = root.appendingPathComponent("system_data/0100000000000802/files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("owned-test-data".utf8)
        try bytes.write(to: folder.appendingPathComponent("ShapeMid.dat"))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let resource: [String: Any] = ["titleId": "0100000000000802", "name": "MiiModel", "relativePath": "system_data/0100000000000802/files", "contentSha256": String(repeating: "1", count: 64), "bytes": bytes.count,
            "files": [["path": "ShapeMid.dat", "bytes": bytes.count, "sha256": hash]]]
        let manifest: [String: Any] = ["formatVersion": 1, "firmwareVersion": "22.5.0", "contentDigest": String(repeating: "2", count: 64), "importedAt": "2026-10-28T00:00:00Z", "sourceKind": "directory", "archiveCount": 238, "resources": [resource]]
        try write(manifest, root: root)
        return (root, manifest)
    }
    private func write(_ manifest: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }
    func testValidatedCatalogExposesTheExactSystemDataRoot() throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let imported = try FirmwareLibrary.load(at: root, verifyHashes: true)
        XCTAssertEqual(imported.catalog.firmwareVersion, "22.5.0")
        XCTAssertEqual(imported.systemDataURL, root.appendingPathComponent("system_data", isDirectory: true))
        XCTAssertEqual(imported.catalog.resources.first?.titleId, "0100000000000802")
    }
    func testHashVerificationRejectsSameSizeTampering() throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("system_data/0100000000000802/files/ShapeMid.dat")
        try Data("different-data!".utf8).write(to: file)
        XCTAssertThrowsError(try FirmwareLibrary.load(at: root, verifyHashes: true))
    }
    func testCatalogRejectsPathTraversalAndWrongResourceRoot() throws {
        let (root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for invalid in ["../outside", "system_data/0100000000000802/files/../../outside"] {
            var manifest = original; var resource = (manifest["resources"] as! [[String: Any]])[0]
            resource["relativePath"] = invalid; manifest["resources"] = [resource]
            try write(manifest, root: root)
            XCTAssertThrowsError(try FirmwareLibrary.load(at: root))
        }
    }
    func testLibraryDoesNotPublishIncompleteOrHiddenImports() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("nx-fw-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".import-incomplete"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("invalid"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        XCTAssertTrue(FirmwareLibrary.installed(in: library).isEmpty)
    }
}
