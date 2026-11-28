import CommonCrypto
import Foundation
import Security

/// The code-signing identity Studio signs a Mac port with.
///
/// An ad-hoc signature's designated requirement is its cdhash, so every rebuild is
/// new code to macOS: the login keychain's "Always Allow" for the Nextendo
/// credential holds only until the next build, and the port asks again. A
/// certificate's designated requirement names the identifier and the certificate,
/// so it stays the same across rebuilds. Studio uses the creator's own Apple
/// Development (or Developer ID Application) certificate for the Team ID set for
/// iOS, and falls back to ad-hoc when there is none.
public enum MacSigningIdentity {
    /// The SHA-1 of the best identity for `teamID` in `security find-identity -v -p codesigning` output.
    /// Developer ID Application is preferred, then Apple Development; nil when neither belongs to the team.
    /// The name's parenthesized ID is the developer's, not always the team's: the team is the
    /// certificate subject's organizational unit, which `teamOf` returns for a SHA-1.
    public static func select(fromFindIdentityOutput output: String, teamID: String, teamOf: (String) -> String?) -> String? {
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        var best: (rank: Int, hash: String)?
        for line in output.split(whereSeparator: \.isNewline) {
            // `  1) <40 hex> "Apple Development: name (TEAMID)"`; revoked or expired identities are not listed with -v.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[0].hasSuffix(")"), valid(String(fields[1])) else { continue }
            let name = fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let hash = fields[1].uppercased()
            guard teamOf(hash)?.uppercased() == team else { continue }
            let rank = name.hasPrefix("Developer ID Application:") ? 0 : name.hasPrefix("Apple Development:") ? 1 : nil
            guard let rank, best.map({ rank < $0.rank }) ?? true else { continue }
            best = (rank, hash)
        }
        return best?.hash
    }

    /// A 40-character hexadecimal SHA-1, the form `codesign --sign` accepts without ambiguity.
    public static func valid(_ hash: String) -> Bool {
        hash.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil
    }

    /// Looks the identity up in the user's keychains. Listing identities reads no private key.
    public static func find(teamID: String?, using runner: ProcessRunner) async -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        let command = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                                     arguments: ["find-identity", "-v", "-p", "codesigning"],
                                     redactedDescription: "security find-identity")
        guard let result = try? await runner.run(command), result.exitCode == 0 else { return nil }
        let teams = certificateTeams()
        return select(fromFindIdentityOutput: result.output, teamID: teamID) { teams[$0] }
    }

    /// Subject organizational unit by certificate SHA-1, for the certificates in the user's keychains.
    static func certificateTeams() -> [String: String] {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let certificates = items as? [SecCertificate] else { return [:] }
        var teams: [String: String] = [:]
        for certificate in certificates {
            guard let unit = organizationalUnit(of: certificate) else { continue }
            let der = SecCertificateCopyData(certificate) as Data
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            der.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(der.count), &digest) }
            teams[digest.map { String(format: "%02X", $0) }.joined()] = unit
        }
        return teams
    }

    private static func organizationalUnit(of certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        return fields.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String) }?[kSecPropertyKeyValue as String] as? String
    }
}
