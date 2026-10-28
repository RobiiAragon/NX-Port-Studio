import Foundation

actor MobileNextendoCallback: NextendoCallbackReceiver {
    static let redirect = URL(string: "nxnative-nextendo://callback")!
    private var started = false
    private var finished: Result<URL, NextendoError>?
    private var continuation: CheckedContinuation<URL, Error>?

    func start() throws -> URL {
        guard !started else { throw NextendoError.authorizationUnavailable }
        started = true
        return Self.redirect
    }
    func callback() async throws -> URL {
        guard started else { throw NextendoError.authorizationUnavailable }
        if let finished { return try finished.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func deliver(_ result: Result<URL, NextendoError>) {
        guard finished == nil else { return }
        finished = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result.mapError { $0 as Error })
        }
    }
    func cancel() { deliver(.failure(.authorizationUnavailable)) }
}

final class MobileNextendoCallbackPool: @unchecked Sendable {
    private let lock = NSLock()
    private var last: MobileNextendoCallback?
    func make() -> MobileNextendoCallback {
        lock.withLock { let value = MobileNextendoCallback(); last = value; return value }
    }
    var latest: MobileNextendoCallback? { lock.withLock { last } }
}

@MainActor protocol MobileNextendoBrowsing: AnyObject {
    func open(_ request: NextendoSignInRequest, receiver: MobileNextendoCallback) -> Bool
    func cancel()
}
