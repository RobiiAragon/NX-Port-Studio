// The native host calls this on its existing guest worker, before the SDK.
// The primary AppKit thread keeps serving events while Swift awaits the bounded
// account transaction. Only completion crosses this bridge, never account data.
import Foundation

enum MacGameAccountPreparation {
    static func run(_ prepare: @escaping @Sendable () async throws -> Void) {
        guard !Thread.isMainThread else {
            fputs("[RED] launcher: account preparation cannot wait on the AppKit thread\n", stderr)
            return
        }
        let finished = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { finished.signal() }
            do { try await prepare() }
            catch {
                if let accountError = error as? NextendoError, case let .accountHTTPStatus(step, status) = accountError {
                    fputs("[RED] launcher: account preparation failed operation=\(step.rawValue) http=\(status)\n", stderr)
                } else {
                    fputs("[RED] launcher: account preparation failed; stored account validation remains in effect\n", stderr)
                }
            }
        }
        finished.wait()
    }
}

@_cdecl("dm_mac_prepare_game_account")
public func dmMacPrepareGameAccount() {
    MacGameAccountPreparation.run {
        _ = try await NextendoAccountService().prepareGameAccount(forceGameRefresh: true)
    }
}
