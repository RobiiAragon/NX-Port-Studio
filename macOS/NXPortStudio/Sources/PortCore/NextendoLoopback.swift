import Foundation
@preconcurrency import Network

/// One-use OAuth callback listener. Mutable state is confined to its private serial queue.
public final class NextendoLoopbackServer: NextendoCallbackReceiver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.nxnative.nextendo.loopback")
    private let listener: NWListener
    private var started = false
    private var redirect: URL?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    public func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.started, self.result == nil else { continuation.resume(throwing: NextendoError.authorizationUnavailable); return }
                    self.started = true; self.ready = continuation
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback") else {
                                self.finish(.failure(NextendoError.requestFailed)); return
                            }
                            self.redirect = url
                            let ready = self.ready; self.ready = nil; ready?.resume(returning: url)
                        case .failed: self.finish(.failure(NextendoError.requestFailed))
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }; self.accept(connection)
                    }
                    self.listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                        guard let self else { return }
                        if self.result == nil { self.finish(.failure(NextendoError.authorizationExpired)) }
                    }
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    public func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else if !self.started || self.waiter != nil { continuation.resume(throwing: NextendoError.authorizationUnavailable) }
                    else { self.waiter = continuation }
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    public func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.result == nil { self.finish(.failure(CancellationError())) }
                self.listener.cancel()
                for connection in self.connections.values { connection.cancel() }
                self.connections.removeAll()
                continuation.resume()
            }
        }
    }
    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value
        let ready = self.ready; self.ready = nil
        if let ready {
            if case .failure(let error) = value { ready.resume(throwing: error) }
            else { ready.resume(throwing: NextendoError.requestFailed) }
        }
        let waiter = self.waiter; self.waiter = nil; waiter?.resume(with: value)
        listener.cancel()
    }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection; connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: id)?.cancel()
        }
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - accumulated.count) { data, _, complete, error in
            var received = accumulated; if let data { received.append(data) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handle(received, connection: connection)
            } else if error != nil || complete || received.count >= 8192 {
                self.reply(connection, status: "400 Bad Request", message: "Invalid sign-in response.")
            } else { self.receive(connection, accumulated: received) }
        }
    }
    private func handle(_ request: Data, connection: NWConnection) {
        guard result == nil, let redirect, let text = String(data: request, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else {
            reply(connection, status: "400 Bad Request", message: "Invalid sign-in response."); return
        }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              parts[1].hasPrefix("/callback?"),
              let callback = URL(string: "http://127.0.0.1:\(redirect.port!)\(parts[1])") else {
            reply(connection, status: "400 Bad Request", message: "Invalid sign-in response."); return
        }
        reply(connection, status: "200 OK", message: "Sign-in response received. Return to NX Port Studio.")
        finish(.success(callback))
    }
    private func reply(_ connection: NWConnection, status: String, message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            self.connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel()
        })
    }
}
