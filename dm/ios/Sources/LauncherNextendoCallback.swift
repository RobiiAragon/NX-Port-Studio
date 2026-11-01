import Foundation

actor MobileNextendoCallback: NextendoCallbackReceiver {
    private let listener: NextendoLoopbackServer
    private var listening: Task<Void, Never>?
    private var started = false
    private var finished: Result<URL, NextendoError>?
    private var continuation: CheckedContinuation<URL, Error>?

    init() throws { listener = try NextendoLoopbackServer() }
    func start() async throws -> URL {
        guard !started else { throw NextendoError.authorizationUnavailable }
        started = true
        // Nextendo's emulator client policy requires an ephemeral IPv4 loopback
        // redirect on mobile too. The authorization code never leaves the phone.
        let redirect = try await listener.start()
        listening = Task { [weak self, listener] in
            do { let callback = try await listener.callback(); await self?.deliver(.success(callback)) }
            catch { await self?.deliver(.failure((error as? NextendoError) ?? .authorizationUnavailable)) }
        }
        return redirect
    }
    func callback() async throws -> URL {
        guard started else { throw NextendoError.authorizationUnavailable }
        if let finished { return try finished.get() }
        guard continuation == nil else { throw NextendoError.authorizationUnavailable }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func deliver(_ result: Result<URL, NextendoError>) {
        guard finished == nil else { return }
        finished = result
        listening?.cancel(); listening = nil
        Task { await listener.cancel() }
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result.mapError { $0 as Error })
        }
    }
    func cancel() async { deliver(.failure(.authorizationUnavailable)); await listener.cancel() }
}

final class MobileNextendoCallbackPool: @unchecked Sendable {
    private let lock = NSLock()
    private var last: MobileNextendoCallback?
    func make() throws -> MobileNextendoCallback {
        try lock.withLock { let value = try MobileNextendoCallback(); last = value; return value }
    }
    var latest: MobileNextendoCallback? { lock.withLock { last } }
}

@MainActor protocol MobileNextendoBrowsing: AnyObject {
    func open(_ request: NextendoSignInRequest, receiver: MobileNextendoCallback) -> Bool
    func cancel()
}
