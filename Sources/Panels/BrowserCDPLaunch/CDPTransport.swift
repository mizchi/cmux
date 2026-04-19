import Foundation

/// Byte-stream transport for CDP's JSON-RPC frames. Abstracted behind a
/// protocol so ChromiumCDPClient can be unit-tested against a FakeTransport
/// without a real WebSocket.
protocol CDPTransport: AnyObject {
    func start() async throws
    func stop()
    func send(_ data: Data) async throws
    /// One AsyncStream covers the lifetime of this transport. Call exactly once
    /// after start() (or at most once per transport lifetime).
    func makeIncoming() -> AsyncStream<Data>
}

final class CDPWebSocketTransport: CDPTransport {
    private let url: URL
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var stream: AsyncStream<Data>?
    private var continuation: AsyncStream<Data>.Continuation?
    private var incomingDelivered = false

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        // Chromium 147+ enforces `--remote-allow-origins` and rejects
        // WebSocket upgrades whose request lacks an Origin header. Set
        // Origin explicitly to a localhost value; `*` in the flag
        // (which we pass at launch) matches any origin as long as the
        // header is present.
        var request = URLRequest(url: url)
        let origin = "http://\(url.host ?? "127.0.0.1"):\(url.port ?? 0)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)

        lock.lock()
        self.stream = stream
        self.continuation = continuation
        self.session = session
        self.task = task
        lock.unlock()

        task.resume()
        Task { [weak self] in await self?.readLoop() }
    }

    func stop() {
        lock.lock()
        let task = self.task
        let session = self.session
        let continuation = self.continuation
        self.task = nil
        self.session = nil
        self.continuation = nil
        // Keep `stream` so any consumer still iterating sees the finish.
        lock.unlock()

        task?.cancel(with: .normalClosure, reason: nil)
        continuation?.finish()
        session?.invalidateAndCancel()
    }

    func send(_ data: Data) async throws {
        lock.lock()
        let task = self.task
        lock.unlock()
        guard let task else { throw CDPError.transportNotStarted }
        try await task.send(.data(data))
    }

    func makeIncoming() -> AsyncStream<Data> {
        lock.lock()
        defer { lock.unlock() }
        precondition(!incomingDelivered, "CDPWebSocketTransport.makeIncoming called twice")
        guard let stream else {
            preconditionFailure("CDPWebSocketTransport.makeIncoming called before start()")
        }
        incomingDelivered = true
        return stream
    }

    private func readLoop() async {
        while true {
            lock.lock()
            let task = self.task
            let continuation = self.continuation
            lock.unlock()
            guard let task, let continuation else { return }
            do {
                let message = try await task.receive()
                switch message {
                case .data(let d):
                    continuation.yield(d)
                case .string(let s):
                    continuation.yield(Data(s.utf8))
                @unknown default:
                    continue
                }
            } catch {
                lock.lock()
                let cont = self.continuation
                self.continuation = nil
                lock.unlock()
                cont?.finish()
                return
            }
        }
    }
}

enum CDPError: Error, CustomStringConvertible {
    case transportNotStarted
    case notConnected
    case malformedResponse(String)
    case remote(code: Int, message: String)
    case requestTimedOut(method: String)

    var description: String {
        switch self {
        case .transportNotStarted: return "CDP transport not started"
        case .notConnected: return "CDP client not connected"
        case .malformedResponse(let s): return "Malformed CDP response: \(s)"
        case .remote(let code, let message): return "CDP error \(code): \(message)"
        case .requestTimedOut(let method): return "CDP request timed out: \(method)"
        }
    }
}
