import Foundation
import CryptoKit

public enum NextendoCatalogError: LocalizedError, Equatable, Sendable {
    case invalidDocument, invalidSignature, expired, rollback, unavailable, httpStatus(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "Nextendo's service catalog has an unsupported format."
        case .invalidSignature: return "Nextendo's service catalog signature could not be verified."
        case .expired: return "Nextendo's service catalog has expired. Refresh it before checking online requirements."
        case .rollback: return "Nextendo returned an older service catalog. The newer verified copy was retained."
        case .unavailable: return "Nextendo's service catalog is unavailable."
        case .httpStatus(let value): return "Nextendo's service catalog returned HTTP \(value)."
        }
    }
}

/// Catalog eligibility is a service-policy check, not proof that the native networking implementation can play this game.
public enum NextendoGameEligibility: Sendable, Equatable {
    case accepted, notListed, disabled, catalogUnavailable, catalogExpired, versionUnknown
    case versionNotAccepted([String]), unsupportedCapabilities([String]), unsupportedPolicy
}

public enum NextendoVersionPolicy: Sendable, Equatable { case exact([String]), any, unsupported }

public struct NextendoGamePolicy: Sendable, Equatable, Identifiable {
    public let titleIDs: [String]
    public let name: String
    public let enabled: Bool
    public let protocolName: String?
    public let requiredCapabilities: [String]
    public let versionPolicy: NextendoVersionPolicy
    public let recommendedVersion: String?
    public var id: String { titleIDs[0] }
    public func evaluate(installedVersion: String?, supportedCapabilities: Set<String> = NextendoCatalogVerifier.capabilities) -> NextendoGameEligibility {
        guard enabled else { return .disabled }
        let unknown = requiredCapabilities.filter { !supportedCapabilities.contains($0) }
        guard unknown.isEmpty else { return .unsupportedCapabilities(unknown) }
        switch versionPolicy {
        case .any: return .accepted
        case .unsupported: return .unsupportedPolicy
        case .exact(let accepted):
            guard let installedVersion, !installedVersion.isEmpty else { return .versionUnknown }
            return accepted.contains(installedVersion) ? .accepted : .versionNotAccepted(accepted)
        }
    }
}

public struct NextendoVerifiedCatalog: Sendable, Equatable {
    public let revision: Int64
    public let issuedAt: Date
    public let expiresAt: Date
    public let games: [NextendoGamePolicy]
    public func evaluate(titleID: String, installedVersion: String?, at now: Date = Date(),
                         supportedCapabilities: Set<String> = NextendoCatalogVerifier.capabilities) -> NextendoGameEligibility {
        guard expiresAt > now, issuedAt <= now.addingTimeInterval(300) else { return .catalogExpired }
        guard let game = games.first(where: { $0.titleIDs.contains(titleID.lowercased()) }) else { return .notListed }
        return game.evaluate(installedVersion: installedVersion, supportedCapabilities: supportedCapabilities)
    }
}

public struct NextendoCatalogVerifier: Sendable {
    public static let capabilities: Set<String> = ["versions.exact.v1", "versions.any.v1"]
    public static let officialPublicKey = Data(base64Encoded: "xI+atR6VesrCH89ZDZD4t3WQLcYOFEhk5F0HLMzgWk4=")!
    private let publicKey: Data
    public init(publicKey: Data = Self.officialPublicKey) { self.publicKey = publicKey }
    public func verify(_ envelope: Data, at now: Date = Date(), minimumRevision: Int64? = nil,
                       allowExpired: Bool = false) throws -> NextendoVerifiedCatalog {
        let outer = try NextendoStrictJSON.object(envelope)
        guard outer["key_id"] as? String == "catalog-key-1", let encoded = outer["payload"] as? String,
              let signature = outer["signature"] as? String, let payload = Data(base64Encoded: encoded), payload.base64EncodedString() == encoded,
              let sig = Data(base64Encoded: signature), sig.base64EncodedString() == signature, sig.count == 64 else { throw NextendoCatalogError.invalidDocument }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(sig, for: payload) else {
            throw NextendoCatalogError.invalidSignature
        }
        let object = try NextendoStrictJSON.object(payload)
        guard object["document_type"] as? String == "game_catalog", Self.integer(object["schema_version"]) == 1,
              let revision = Self.integer(object["revision"]), revision > 0,
              let issued = Self.date(object["issued_at"]), let expiry = Self.date(object["expires_at"]),
              expiry > issued, expiry.timeIntervalSince(issued) <= 86_400, issued <= now.addingTimeInterval(300),
              let rawGames = object["games"] as? [[String: Any]], rawGames.count <= 10_000 else { throw NextendoCatalogError.invalidDocument }
        if !allowExpired && expiry <= now { throw NextendoCatalogError.expired }
        if let minimumRevision, revision < minimumRevision { throw NextendoCatalogError.rollback }
        var seen = Set<String>(), games: [NextendoGamePolicy] = []
        for raw in rawGames {
            guard let ids = raw["title_ids"] as? [String], (1...32).contains(ids.count) else { throw NextendoCatalogError.invalidDocument }
            for id in ids {
                guard id.range(of: "^[A-Fa-f0-9]{16}$", options: .regularExpression) != nil,
                      UInt64(id, radix: 16) != 0, seen.insert(id.lowercased()).inserted else { throw NextendoCatalogError.invalidDocument }
            }
            games.append(Self.policy(raw, ids: ids.map { $0.lowercased() }))
        }
        return NextendoVerifiedCatalog(revision: revision, issuedAt: issued, expiresAt: expiry, games: games)
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.hasSuffix("Z"), text.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
    }
    private static func text(_ value: Any?, max: Int, nonempty: Bool = true) -> String? {
        guard let text = value as? String, (!nonempty || !text.isEmpty), text.count <= max,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    private static func policy(_ raw: [String: Any], ids: [String]) -> NextendoGamePolicy {
        let name = text(raw["name"], max: 256) ?? ids[0]
        let proto = text(raw["protocol"], max: 32)
        let enabledNumber = raw["enabled"] as? NSNumber
        let enabled = enabledNumber.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        var caps: [String] = [], policy: NextendoVersionPolicy = .unsupported, recommended: String?
        if let values = raw["required_capabilities"] as? [String], values.count <= 64, Set(values).count == values.count,
           values.allSatisfy({ $0.range(of: "^[a-z0-9._-]{1,64}$", options: .regularExpression) != nil }) {
            caps = values
            if let versions = raw["versions"] as? [String: Any], let kind = versions["policy"] as? String {
                if kind == "any", caps.contains("versions.any.v1"), versions["accepted"] == nil, versions["recommended"] == nil { policy = .any }
                if kind == "exact", caps.contains("versions.exact.v1"), let accepted = versions["accepted"] as? [String],
                   (1...64).contains(accepted.count), Set(accepted).count == accepted.count,
                   accepted.allSatisfy({ text($0, max: 32) != nil && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    let preferred = versions["recommended"] as? String ?? accepted[0]
                    if accepted.contains(preferred) { policy = .exact(accepted); recommended = preferred }
                }
            }
        }
        return NextendoGamePolicy(titleIDs: ids, name: name, enabled: enabled, protocolName: proto,
                                  requiredCapabilities: caps, versionPolicy: policy, recommendedVersion: recommended)
    }
}

public enum NextendoCatalogFreshness: String, Sendable { case fresh, expired, unavailable }
public struct NextendoCatalogSnapshot: Sendable {
    public let catalog: NextendoVerifiedCatalog?
    public let fetchedAt: Date?
    public let refreshError: NextendoCatalogError?
    public func freshness(at now: Date = Date()) -> NextendoCatalogFreshness {
        guard let catalog else { return .unavailable }
        return catalog.expiresAt > now && catalog.issuedAt <= now.addingTimeInterval(300) ? .fresh : .expired
    }
    public func evaluate(titleID: String, installedVersion: String?, at now: Date = Date(),
                         supportedCapabilities: Set<String> = NextendoCatalogVerifier.capabilities) -> NextendoGameEligibility {
        catalog?.evaluate(titleID: titleID, installedVersion: installedVersion, at: now, supportedCapabilities: supportedCapabilities) ?? .catalogUnavailable
    }
}

public actor NextendoCatalogService {
    public static let endpoint = URL(string: "https://nextendo.network/service-catalog/v1/game-catalog")!
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NX Port Studio/Nextendo/catalog-cache.json")
    }
    private struct CacheRecord: Codable { let schemaVersion: Int; let fetchedAt: Date; let envelope: Data }
    private let http: any NextendoHTTPClient
    private let cacheURL: URL?
    private let verifier: NextendoCatalogVerifier
    private let now: @Sendable () -> Date
    private var catalog: NextendoVerifiedCatalog?
    private var fetchedAt: Date?
    private var refreshError: NextendoCatalogError?
    public init(http: any NextendoHTTPClient = NextendoURLSessionClient(), cacheURL: URL? = NextendoCatalogService.defaultCacheURL,
                verifier: NextendoCatalogVerifier = NextendoCatalogVerifier(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.cacheURL = cacheURL; self.verifier = verifier; self.now = now
        if let cacheURL, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000,
           let data = try? Data(contentsOf: cacheURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            if let saved = try? decoder.decode(CacheRecord.self, from: data), saved.schemaVersion == 1,
               let verified = try? verifier.verify(saved.envelope, at: now(), allowExpired: true) {
                catalog = verified
                if saved.fetchedAt <= now().addingTimeInterval(300) { fetchedAt = saved.fetchedAt }
            } else { refreshError = .invalidDocument }
        }
    }
    public func snapshot() -> NextendoCatalogSnapshot { .init(catalog: catalog, fetchedAt: fetchedAt, refreshError: refreshError) }
    @discardableResult public func refresh() async throws -> NextendoCatalogSnapshot {
        do {
            var request = URLRequest(url: Self.endpoint); request.httpMethod = "GET"
            let response: NextendoHTTPResponse
            do { response = try await http.send(request) } catch is CancellationError { throw CancellationError() } catch { throw NextendoCatalogError.unavailable }
            try Task.checkCancellation()
            guard response.statusCode == 200 else { throw NextendoCatalogError.httpStatus(response.statusCode) }
            let verified = try verifier.verify(response.data, at: now(), minimumRevision: catalog?.revision)
            if let catalog, verified.revision == catalog.revision, verified.issuedAt < catalog.issuedAt { throw NextendoCatalogError.rollback }
            let fetched = now()
            if let cacheURL {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(CacheRecord(schemaVersion: 1, fetchedAt: fetched, envelope: response.data))
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
            }
            catalog = verified; fetchedAt = fetched; refreshError = nil
            return snapshot()
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = (error as? NextendoCatalogError) ?? .unavailable
            refreshError = failure; throw failure
        }
    }
}

/// Foundation validates syntax; this bounded second pass also rejects duplicate object keys (including escaped spellings).
private struct NextendoStrictJSON {
    private let bytes: [UInt8]
    private var index = 0
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NextendoCatalogError.invalidDocument }
        var scanner = Self(bytes: Array(data)); try scanner.value(depth: 0); scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw NextendoCatalogError.invalidDocument }
        return object
    }
    private mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func string() throws -> String {
        let start = index; guard index < bytes.count, bytes[index] == 34 else { throw NextendoCatalogError.invalidDocument }; index += 1
        while index < bytes.count {
            if bytes[index] == 34 { index += 1; return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if bytes[index] == 92 { index += 1 }; index += 1
        }
        throw NextendoCatalogError.invalidDocument
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw NextendoCatalogError.invalidDocument }; whitespace()
        guard index < bytes.count else { throw NextendoCatalogError.invalidDocument }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 {
            index += 1; whitespace(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while index < bytes.count {
                whitespace(); let key = try string(); guard keys.insert(key).inserted else { throw NextendoCatalogError.invalidDocument }
                whitespace(); guard index < bytes.count, bytes[index] == 58 else { throw NextendoCatalogError.invalidDocument }; index += 1
                try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                guard index < bytes.count, bytes[index] == 44 else { throw NextendoCatalogError.invalidDocument }; index += 1
            }
        } else if bytes[index] == 91 {
            index += 1; whitespace(); if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while index < bytes.count {
                try value(depth: depth + 1); whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                guard index < bytes.count, bytes[index] == 44 else { throw NextendoCatalogError.invalidDocument }; index += 1
            }
        } else {
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw NextendoCatalogError.invalidDocument }; return
        }
        throw NextendoCatalogError.invalidDocument
    }
}
