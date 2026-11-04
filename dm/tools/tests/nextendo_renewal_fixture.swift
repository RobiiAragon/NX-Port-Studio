// Two independent production service actors share synthetic files and the real
// lease implementation. No browser, Keychain or network transport is used.
import Foundation
import Darwin

private struct FixtureStore: NextendoCredentialStore {
    let root: URL
    let worker: String
    func load() throws -> NextendoSession? {
        try NextendoSession.decodeStored(Data(contentsOf: root.appendingPathComponent("account.json")))
    }
    func save(_ session: NextendoSession) throws {
        let path = root.appendingPathComponent("account.json")
        try session.encodedForStorage().write(to: path,options:.atomic)
        guard chmod(path.path,0o600) == 0 else { throw NextendoError.requestFailed }
    }
    func remove() throws { try FileManager.default.removeItem(at:root.appendingPathComponent("account.json")) }
    func acquireExclusiveLease() async throws -> any NextendoCredentialLease {
        try Data().write(to:root.appendingPathComponent("waiting-"+worker))
        return try await NextendoFileCredentialLease.acquire(at:root.appendingPathComponent("locks/account.lock"))
    }
}
private actor FixtureHTTP: NextendoHTTPClient {
    let root: URL
    init(_ root: URL) { self.root = root }
    func send(_ request: URLRequest) async throws -> NextendoHTTPResponse {
        let path = root.appendingPathComponent("counts.json")
        var counts = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Int]
        counts["requests",default:0] += 1
        var reply: [String:Any]
        switch request.url!.path {
        case "/api/oauth/token":
            guard counts["refresh",default:0] == 0,
                  let body = request.httpBody, let text = String(data:body,encoding:.utf8),
                  let form = URLComponents(string:"https://fixture.invalid/?"+text),
                  form.queryItems?.first(where: { $0.name == "refresh_token" })?.value == "sentinel-old-refresh" else { throw NextendoError.invalidResponse }
            counts["refresh",default:0] += 1
            try Data().write(to:root.appendingPathComponent("refresh-started"))
            let deadline = ContinuousClock.now.advanced(by:.seconds(10))
            while !FileManager.default.fileExists(atPath:root.appendingPathComponent("release").path) {
                guard ContinuousClock.now < deadline else { throw NextendoError.requestFailed }
                try await Task.sleep(for:.milliseconds(10))
            }
            reply = ["access_token":"sentinel-new-access","refresh_token":"sentinel-new-refresh","token_type":"Bearer","expires_in":3600]
        case "/api/oauth/userinfo": reply = ["pid":42,"username":"synthetic"]
        case "/api/nex-token": reply = ["pid":42,"username":"synthetic","nex_token":Self.proof(Date().addingTimeInterval(86400)),"expires_in":86400]
        default: throw NextendoError.requestFailed
        }
        try JSONSerialization.data(withJSONObject:counts).write(to:path,options:.atomic)
        return .init(data:try JSONSerialization.data(withJSONObject:reply),statusCode:200)
    }
    static func proof(_ expiry: Date) -> String {
        "nx2." + Data("42.synthetic.\(Int64(expiry.timeIntervalSince1970))".utf8).nextendoBase64URL + "." + Data(repeating:0,count:32).nextendoBase64URL
    }
}
@main private struct RenewalFixture {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else { exit(64) }
        let root = URL(fileURLWithPath:args[2]), store = FixtureStore(root:root,worker:args.count == 4 ? args[3] : "seed")
        if args[1] == "seed" {
            let now = Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970)), expiry = now.addingTimeInterval(-10)
            let grant = NextendoRenewalGrant(clientID:"nxnative-own-fixture",accessToken:"sentinel-old-access",refreshToken:"sentinel-old-refresh",expiresAt:expiry,scopes:["identity","friends","game.matchmaking"])
            try store.save(NextendoSession(tokenKind:.nex,token:FixtureHTTP.proof(expiry),identity:.init(pid:42,username:"synthetic"),scopes:[],createdAt:now.addingTimeInterval(-1000),expiresAt:expiry).withRenewal(grant))
            try JSONSerialization.data(withJSONObject:["requests":0,"refresh":0]).write(to:root.appendingPathComponent("counts.json"))
        } else if args[1] == "worker" {
            let service = NextendoAccountService(store:store,http:FixtureHTTP(root),makeReceiver:{ throw NextendoError.authorizationUnavailable })
            let summary = try await service.prepareGameAccount()
            guard summary?.hasNEXCredential == true else { exit(65) }
            print("Synthetic worker ready; no Keychain or network")
        } else { exit(64) }
    }
}
