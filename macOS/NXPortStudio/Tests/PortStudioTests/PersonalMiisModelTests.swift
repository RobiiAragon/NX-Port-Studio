import Foundation
import XCTest
@testable import PortStudio

@MainActor
final class PersonalMiisModelTests: XCTestCase {
    func testCancelledReadDoesNotReportLibraryCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mii read cancellation \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        // A slow metadata reader never opens the personal library passed to it.
        try Data("import time\ntime.sleep(30)\n".utf8).write(to: root.appendingPathComponent("scripts/import_miis.py"))
        let model = StudioModel()
        model.repositoryPath = root.path
        model.miiLibraryError = "previous status"
        let read = Task { await model.reloadMiis() }
        for _ in 0..<100 where !model.isLoadingMiis {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.isLoadingMiis)
        read.cancel()
        await read.value
        XCTAssertFalse(model.isLoadingMiis)
        XCTAssertEqual(model.miiLibraryError, "previous status")
        XCTAssertEqual(model.personalMiis.count, 0)
    }
}
