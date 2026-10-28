import XCTest
import CryptoKit
@testable import PortCore

private actor CatalogHTTP: NextendoHTTPClient {
    var replies: [NextendoHTTPResponse]
    init(_ replies: [NextendoHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        guard request.url == NextendoCatalogService.endpoint, !replies.isEmpty else { throw NextendoCatalogError.unavailable }
        return replies.removeFirst()
    }
}

@MainActor final class NextendoCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)) // synthetic test signing key
    private var verifier: NextendoCatalogVerifier { .init(publicKey: key.publicKey.rawRepresentation) }
    private func game(ids: [String] = ["0100152000022000"], enabled: Bool = true, capabilities: [String] = ["versions.exact.v1"],
                      versions: [String: Any] = ["policy": "exact", "accepted": ["4.0.1"], "recommended": "4.0.1"]) -> [String: Any] {
        ["title_ids": ids, "name": "Synthetic game", "enabled": enabled, "required_capabilities": capabilities, "versions": versions]
    }
    private func payload(revision: Int = 15, issued: Date? = nil, expires: Date? = nil, games: [[String: Any]]? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: ["document_type": "game_catalog", "schema_version": 1, "revision": revision,
            "issued_at": formatter.string(from: issued ?? now.addingTimeInterval(-60)), "expires_at": formatter.string(from: expires ?? now.addingTimeInterval(7200)),
            "games": games ?? [game()]], options: .sortedKeys)
    }
    private func signed(_ payload: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["key_id": "catalog-key-1", "payload": payload.base64EncodedString(),
                                                   "signature": try key.signature(for: payload).base64EncodedString()], options: .sortedKeys)
    }
    func testValidSignatureAndExactVersionAreServicePolicyOnly() throws {
        let catalog = try verifier.verify(signed(payload()), at: now)
        XCTAssertEqual(catalog.revision, 15)
        XCTAssertEqual(catalog.evaluate(titleID: "0100152000022000", installedVersion: "4.0.1", at: now), .accepted)
        XCTAssertEqual(catalog.evaluate(titleID: "0100152000022000", installedVersion: "3.0.5", at: now), .versionNotAccepted(["4.0.1"]))
        XCTAssertEqual(catalog.evaluate(titleID: "0100152000022000", installedVersion: nil, at: now), .versionUnknown)
        XCTAssertEqual(catalog.evaluate(titleID: "0100152000022000", installedVersion: "4.0.1.0", at: now), .versionNotAccepted(["4.0.1"]))
        XCTAssertEqual(catalog.evaluate(titleID: "0100000000000001", installedVersion: "1", at: now), .notListed)
    }
    func testTamperingUnknownKeyAndDuplicateJSONFail() throws {
        var envelope = try JSONSerialization.jsonObject(with: signed(payload())) as! [String: Any]
        envelope["payload"] = try payload(revision: 99).base64EncodedString()
        XCTAssertThrowsError(try verifier.verify(JSONSerialization.data(withJSONObject: envelope), at: now)) { error in
            XCTAssertEqual(error as? NextendoCatalogError, .invalidSignature)
        }
        let wrong = NextendoCatalogVerifier(publicKey: Data(repeating: 6, count: 32))
        XCTAssertThrowsError(try wrong.verify(signed(payload()), at: now))
        let body = String(data: try payload(), encoding: .utf8)!.replacingOccurrences(of: "\"revision\":15", with: "\"revision\":15,\"revi\\u0073ion\":16")
        XCTAssertThrowsError(try verifier.verify(signed(Data(body.utf8)), at: now))
        let duplicateEnvelope = Data("{\"key_id\":\"catalog-key-1\",\"key_id\":\"other\"}".utf8)
        XCTAssertThrowsError(try verifier.verify(duplicateEnvelope, at: now))
        var noncanonical = try JSONSerialization.jsonObject(with: signed(payload())) as! [String: Any]
        noncanonical["signature"] = (noncanonical["signature"] as! String).replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try verifier.verify(JSONSerialization.data(withJSONObject: noncanonical), at: now))
    }
    func testValidityExpiryAndRollbackAreEnforced() throws {
        XCTAssertThrowsError(try verifier.verify(signed(payload(expires: now)), at: now)) { XCTAssertEqual($0 as? NextendoCatalogError, .expired) }
        XCTAssertThrowsError(try verifier.verify(signed(payload(issued: now.addingTimeInterval(301))), at: now))
        XCTAssertThrowsError(try verifier.verify(signed(payload(expires: now.addingTimeInterval(90_000))), at: now))
        XCTAssertThrowsError(try verifier.verify(signed(payload(revision: 14)), at: now, minimumRevision: 15)) { XCTAssertEqual($0 as? NextendoCatalogError, .rollback) }
        let expired = try verifier.verify(signed(payload(expires: now)), at: now, allowExpired: true)
        XCTAssertEqual(expired.evaluate(titleID: "0100152000022000", installedVersion: "4.0.1", at: now), .catalogExpired)
    }
    func testEveryTitleAliasCapabilitiesUnknownPolicyAndDisabledEntries() throws {
        let entries = [
            game(ids: ["0100152000022000", "0100152000022001"]),
            game(ids: ["0100000000000002"], capabilities: ["versions.any.v1"], versions: ["policy": "any"]),
            game(ids: ["0100000000000003"], capabilities: ["versions.exact.v1", "future.capability"]),
            game(ids: ["0100000000000004"], enabled: false),
            game(ids: ["0100000000000005"], versions: ["policy": "future"])
        ]
        let catalog = try verifier.verify(signed(payload(games: entries)), at: now)
        XCTAssertEqual(catalog.evaluate(titleID: "0100152000022001", installedVersion: "4.0.1", at: now), .accepted)
        XCTAssertEqual(catalog.evaluate(titleID: "0100000000000002", installedVersion: nil, at: now), .accepted)
        XCTAssertEqual(catalog.evaluate(titleID: "0100000000000003", installedVersion: "4.0.1", at: now), .unsupportedCapabilities(["future.capability"]))
        XCTAssertEqual(catalog.evaluate(titleID: "0100000000000004", installedVersion: "4.0.1", at: now), .disabled)
        XCTAssertEqual(catalog.evaluate(titleID: "0100000000000005", installedVersion: "4.0.1", at: now), .unsupportedPolicy)
        XCTAssertThrowsError(try verifier.verify(signed(payload(games: [game(ids: ["01000000000000a1"]), game(ids: ["01000000000000A1"])])), at: now))
    }
    func testSignedCacheIsReverifiedAndExpiredCopyCannotAuthorize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nextendo catalog tests \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("manifest.json")
        let envelope = try signed(payload())
        let fixed = now
        let service = NextendoCatalogService(http: CatalogHTTP([.init(data: envelope, statusCode: 200)]), cacheURL: cache, verifier: verifier, now: { fixed })
        let refreshed = try await service.refresh()
        XCTAssertEqual(refreshed.freshness(at: now), .fresh)
        let later = now.addingTimeInterval(8000)
        let loaded = NextendoCatalogService(http: CatalogHTTP([]), cacheURL: cache, verifier: verifier, now: { later })
        let snapshot = await loaded.snapshot()
        XCTAssertEqual(snapshot.freshness(at: later), .expired)
        XCTAssertEqual(snapshot.evaluate(titleID: "0100152000022000", installedVersion: "4.0.1", at: later), .catalogExpired)
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        record["envelope"] = Data("tampered".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: record).write(to: cache)
        let corrupted = NextendoCatalogService(http: CatalogHTTP([]), cacheURL: cache, verifier: verifier, now: { fixed })
        let invalid = await corrupted.snapshot()
        XCTAssertEqual(invalid.freshness(at: now), .unavailable); XCTAssertNil(invalid.catalog)
    }
    func testRefreshFailureRetainsOnlyStillValidVerifiedCatalog() async throws {
        let fixed = now
        let service = NextendoCatalogService(http: CatalogHTTP([.init(data: try signed(payload()), statusCode: 200), .init(data: try signed(payload(revision: 14)), statusCode: 200)]),
                                             cacheURL: nil, verifier: verifier, now: { fixed })
        _ = try await service.refresh()
        do { _ = try await service.refresh(); XCTFail("rollback accepted") } catch { XCTAssertEqual(error as? NextendoCatalogError, .rollback) }
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.catalog?.revision, 15); XCTAssertEqual(snapshot.refreshError, .rollback)
        XCTAssertEqual(snapshot.evaluate(titleID: "0100152000022000", installedVersion: "3.0.5", at: now), .versionNotAccepted(["4.0.1"]))
    }
}
