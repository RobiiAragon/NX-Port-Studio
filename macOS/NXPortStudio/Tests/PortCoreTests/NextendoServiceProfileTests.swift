import XCTest
import CryptoKit
@testable import PortCore

private actor ProfileHTTP: NextendoHTTPClient {
    var count = 0
    let certificate: Data
    init(_ certificate: Data) { self.certificate = certificate }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        guard request.url?.host == "raw.githubusercontent.com", request.value(forHTTPHeaderField: "Authorization") == nil,
              request.httpBody == nil else { throw NextendoServiceProfileError.unavailable }
        count += 1
        return .init(data: certificate, statusCode: 200)
    }
}

@MainActor final class NextendoServiceProfileTests: XCTestCase {
    // Original ephemeral test CA; its discarded private key was never published.
    private let ca = Data(base64Encoded: "MIIBrTCCAVSgAwIBAgIUWThS1XZAnXq+u3hPGihk3SG2Tg0wCgYIKoZIzj0EAwIwNDEyMDAGA1UEAwwpT3JpZ2luYWwgTlggUG9ydCBTdHVkaW8gZml4dHVyZSBhdXRob3JpdHkwIBcNMjYxMDMxMTAyNzUzWhgPMjA1NDAzMTgxMDI3NTNaMDQxMjAwBgNVBAMMKU9yaWdpbmFsIE5YIFBvcnQgU3R1ZGlvIGZpeHR1cmUgYXV0aG9yaXR5MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMHcNnkK/JVpM7QcQSg64SAsppII4rwj/WuGcGX77Xbt0BaVARfaGdLZNUnhan7YhhLr8kLICVt0O4xh5gQW/s6NCMEAwHQYDVR0OBBYEFB4/HyLKVvY5L3zrK05hcq4Z+bB+MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0cAMEQCIC8siEsH+aQxr042qL56u7Iz1Xygx9c/lEq9kHnQ9/AwAiAlEBxR+GCaE2/oU2UOillOwBmeZ7b3ajrdmTpDb87+rQ==")!
    private func contract() throws -> NextendoServiceContract {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("dm/net/nextendo-services.json"))) as! [String: Any]
        var provider = value["provider"] as! [String: Any]
        provider["caSHA256"] = NextendoServiceContract.digest(ca); value["provider"] = provider
        return try NextendoServiceContract(data: JSONSerialization.data(withJSONObject: value))
    }
    func testServiceFamiliesAndScopedSharedProvider() throws {
        let value = try contract()
        let regular = String(decoding: try value.routes(titleID: "0100152000022000"), as: UTF8.self)
        XCTAssertTrue(regular.contains("label\tnncs2-*.n.n.srv.nintendo.net\t164.132.111.120"))
        XCTAssertTrue(regular.contains("suffix\tnintendo.net\t51.178.29.194\t@host"))
        XCTAssertFalse(regular.contains("epicgames.dev"))
        XCTAssertTrue(String(decoding: try value.routes(titleID: "0100ab401f136000"), as: UTF8.self).contains("epicgames.dev"))
        XCTAssertTrue(String(decoding: try value.routes(titleID: "01001b300b9be000"), as: UTF8.self).contains("demonware.net"))
        XCTAssertTrue(String(decoding: try value.routes(titleID: "0100ea6014bb8000"), as: UTF8.self).contains("phonescoring.jd.ubisoft.com"))
        for id in ["../bad", String(repeating: "0", count: 16), "invalid"] { XCTAssertThrowsError(try value.routes(titleID: id)) }
    }
    func testAtomicGenerationsVerifiedCacheAndNoCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ProfileHTTP(ca), service = NextendoServiceProfileService(client: http), value = try contract()
        let first = try await service.prepare(contract: value, titleID: "0100152000022000", root: root)
        let original = try Data(contentsOf: first)
        let second = try await service.prepare(contract: value, titleID: "0100152000022000", root: root)
        XCTAssertNotEqual(first, second); XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
        let calls = await http.count; XCTAssertEqual(calls, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: second.deletingLastPathComponent().path)
        XCTAssertEqual(Set(names), ["routes.tsv", "manifest.json", "provider-ca.der"])
        let permissions = try FileManager.default.attributesOfItem(atPath: second.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testWrongCertificateAndSymlinkStorageFailWithoutPublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let service = NextendoServiceProfileService(client: ProfileHTTP(Data("invalid".utf8))), value = try contract()
        do { _ = try await service.prepare(contract: value, titleID: "0100152000022000", root: alias); XCTFail("Unsafe root accepted") }
        catch NextendoServiceProfileError.unsafeStorage { }
        do { _ = try await service.prepare(contract: value, titleID: "0100152000022000", root: root.appendingPathComponent("profiles")); XCTFail("Unpinned CA accepted") }
        catch NextendoServiceProfileError.invalidCertificate { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("profiles").path), [])
    }
}
