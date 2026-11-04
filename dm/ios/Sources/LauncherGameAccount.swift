// Boot calls this on its existing native worker before the SDK. UIKit keeps
// serving events; only completion crosses the bridge, never account data.
import Foundation

enum MobileGameAccountPreparation {
    static func run(_ prepare: @escaping @Sendable () async throws -> Void) {
        guard !Thread.isMainThread else {
            fputs("[RED] launcher: account preparation cannot wait on the UIKit thread\n",stderr)
            return
        }
        let finished = DispatchSemaphore(value:0)
        Task.detached(priority:.userInitiated) {
            defer { finished.signal() }
            do { try await prepare() }
            catch {
                if let accountError = error as? NextendoError,case let .accountHTTPStatus(step,status) = accountError {
                    fputs("[RED] launcher: account preparation failed operation=\(step.rawValue) http=\(status)\n",stderr)
                } else {
                    fputs("[RED] launcher: account preparation failed; stored account validation remains in effect\n",stderr)
                }
            }
        }
        finished.wait()
    }
}

@_cdecl("dm_mobile_prepare_game_account")
public func dmMobilePrepareGameAccount() {
    MobileGameAccountPreparation.run {
        _ = try await NextendoAccountService(store:MobileNextendoCredentialStore()).prepareGameAccount(forceGameRefresh:true)
    }
}
