// Adapter-only fixture. The production Core is separately typechecked; these
// substitutes make accidental browser, Keychain and HTTP access impossible.
import Foundation

enum NextendoAccountStep: String { case gameProof }
enum NextendoError: Error { case accountHTTPStatus(NextendoAccountStep,Int) }
struct MobileNextendoCredentialStore {}
private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var completed = false
    func reset() { lock.withLock { calls = 0; completed = false } }
    func prepare(_ force: Bool) { lock.withLock { precondition(force); calls += 1 } }
    func finish() { lock.withLock { completed = true } }
    func read() -> (Int,Bool) { lock.withLock { (calls,completed) } }
}
private let state = State()
actor NextendoAccountService {
    init(store:MobileNextendoCredentialStore) {}
    func prepareGameAccount(forceGameRefresh:Bool) async throws -> Int? {
        state.prepare(forceGameRefresh)
        try await Task.sleep(for:.milliseconds(10))
        state.finish(); return nil
    }
}
private struct SentinelError: LocalizedError {
    var errorDescription: String? { "DO_NOT_DISPLAY_URL_TOKEN_OR_ID" }
}
@main private struct MobileGameAccountCheck {
    static func main() {
        state.reset()
        MobileGameAccountPreparation.run { state.prepare(true) }
        precondition(state.read().0 == 0,"The UIKit thread must never wait or begin account I/O")
        let done = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            dmMobilePrepareGameAccount()
            precondition(state.read().0 == 1 && state.read().1,"Guest startup must wait until shared preparation completes")
            MobileGameAccountPreparation.run { throw SentinelError() }
            MobileGameAccountPreparation.run { throw NextendoError.accountHTTPStatus(.gameProof,403) }
            done.signal()
        }
        precondition(done.wait(timeout:.now()+3) == .success)
        print("mobile game preparation: worker completion, main-thread guard and sanitized errors passed; no Keychain or network")
    }
}
