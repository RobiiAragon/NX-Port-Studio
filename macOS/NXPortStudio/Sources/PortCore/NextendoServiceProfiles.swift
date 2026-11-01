import Foundation
import CryptoKit
import Security

public enum NextendoServiceProfileError: Error, Sendable { case invalidContract, invalidCertificate, unsafeStorage, unavailable }

/// Public endpoint facts shared by desktop exports and the mobile setup screen.
/// This prepares transport, never account credentials or a claim of gameplay.
public struct NextendoServiceContract: Decodable, Sendable {
    public struct Provider: Decodable, Sendable {
        let server: String, nat: String, caURL: String, caSHA256: String
    }
    public struct Rule: Decodable, Sendable {
        let match: String, host: String, server: String, tls: Bool
    }
    let formatVersion: Int
    let provider: Provider
    let base: [Rule]
    let families: [String: [Rule]]
    let titles: [String: [Rule]]
    let titleFamilies: [String: String]
    let identities: [String: [String: String]]

    public init(data: Data) throws {
        guard data.count <= 65_536 else { throw NextendoServiceProfileError.invalidContract }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard formatVersion == 1, Self.address(provider.server), Self.address(provider.nat),
              provider.caSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let url = URLComponents(string: provider.caURL), url.scheme == "https", url.host == "raw.githubusercontent.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/NextendoNetwork/Prelude-Nextendo/[0-9a-f]{40}/romfs/sd/rootCA.pem$", options: .regularExpression) != nil
        else { throw NextendoServiceProfileError.invalidContract }
    }
    public func routes(titleID: String, protocolName: String? = nil) throws -> Data {
        let id = titleID.lowercased()
        guard id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil, UInt64(id, radix: 16) != 0
        else { throw NextendoServiceProfileError.invalidContract }
        let family = protocolName ?? titleFamilies[id] ?? "nex"
        let rules = base + (families[family] ?? []) + (titles[id] ?? [])
        var seen = Set<String>(), lines = ["NXNEXTENDO_ROUTES_2"]
        for rule in rules {
            let host = rule.host.lowercased(), key = rule.match + ":" + host
            guard ["exact", "suffix", "label"].contains(rule.match),
                  Self.hostname(host.replacingOccurrences(of: "*", with: "x")),
                  rule.match == "label" ? host.filter({ $0 == "*" }).count == 1 : !host.contains("*"),
                  ["server", "nat"].contains(rule.server)
            else { throw NextendoServiceProfileError.invalidContract }
            guard seen.insert(key).inserted else { continue }
            let address = rule.server == "nat" ? provider.nat : provider.server
            let tail = rule.tls ? ["@host", "provider-ca.der", provider.caSHA256] : ["-", "-", "-"]
            lines.append(([rule.match, host, address] + tail).joined(separator: "\t"))
        }
        guard (2...129).contains(lines.count) else { throw NextendoServiceProfileError.invalidContract }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    func certificate(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 65_536 else { throw NextendoServiceProfileError.invalidCertificate }
        let der: Data
        if let pem = String(data: data, encoding: .utf8), pem.contains("-----BEGIN CERTIFICATE-----") {
            let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
            guard text.hasPrefix(begin), text.hasSuffix(end),
                  let decoded = Data(base64Encoded: text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace })
            else { throw NextendoServiceProfileError.invalidCertificate }
            der = decoded
        } else { der = data }
        guard Self.digest(der) == provider.caSHA256, SecCertificateCreateWithData(nil, der as CFData) != nil
        else { throw NextendoServiceProfileError.invalidCertificate }
        return der
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            (1...63).contains($0.utf8.count) && $0.range(of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
        }
    }
    private static func address(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0).map { String($0) } == String($0) }),
              let first = UInt8(parts[0]), first > 0, first < 224, first != 127 else { return false }
        return true
    }
}

public actor NextendoServiceProfileService {
    private let client: any NextendoHTTPClient
    public init(client: any NextendoHTTPClient = NextendoURLSessionClient()) { self.client = client }

    public func prepare(contract: NextendoServiceContract, titleID: String, protocolName: String? = nil, root: URL,
                        includedCertificate: Data? = nil) async throws -> URL {
        let routes = try contract.routes(titleID: titleID, protocolName: protocolName)
        let manager = FileManager.default
        guard !Self.isLink(root) else { throw NextendoServiceProfileError.unsafeStorage }
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cache = root.appendingPathComponent("public-provider-ca.der")
        var ca = includedCertificate.flatMap { try? contract.certificate($0) }
        if !Self.isLink(cache), let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 65_536, let bytes = try? Data(contentsOf: cache), let verified = try? contract.certificate(bytes) { ca = verified }
        if ca == nil {
            var request = URLRequest(url: URL(string: contract.provider.caURL)!)
            request.setValue("NX-Port-Studio", forHTTPHeaderField: "User-Agent")
            let response = try await client.send(request)
            guard response.statusCode == 200 else { throw NextendoServiceProfileError.unavailable }
            ca = try contract.certificate(response.data)
            try Task.checkCancellation()
            guard !Self.isLink(cache) else { throw NextendoServiceProfileError.unsafeStorage }
            try ca!.write(to: cache, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        }
        try Task.checkCancellation()
        // Publish an immutable generation; an existing native policy keeps its
        // borrowed CA buffers until process exit. Failed preparation publishes none.
        let generation = root.appendingPathComponent(titleID.lowercased() + "-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: generation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let files = ["routes.tsv": routes, "provider-ca.der": ca!]
            for (name, bytes) in files {
                let file = generation.appendingPathComponent(name)
                try bytes.write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let manifest: [String: Any] = ["formatVersion": 1, "titleID": titleID.lowercased(),
                "protocol": protocolName.map { $0 as Any } ?? NSNull(),
                "identity": contract.identities[titleID.lowercased()] ?? ["account":"pid", "friends":"pid"],
                "files": files.mapValues(NextendoServiceContract.digest)]
            let file = generation.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return generation.appendingPathComponent("routes.tsv")
        } catch { try? manager.removeItem(at: generation); throw error }
    }
    private static func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}
