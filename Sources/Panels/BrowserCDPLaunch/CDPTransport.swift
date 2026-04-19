import Foundation

/// Byte-stream transport for CDP's JSON-RPC frames. Abstracted behind a
/// protocol so ChromiumCDPClient can be unit-tested against a FakeTransport
/// without a real WebSocket.
protocol CDPTransport: AnyObject {
    func start() async throws
    func stop()
    func send(_ data: Data) async throws
    /// One AsyncStream covers the lifetime of this transport. Consumer
    /// is responsible for cancelling iteration when stop() is called.
    func makeIncoming() -> AsyncStream<Data>
}

final class CDPWebSocketTransport: CDPTransport {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Data>.Continuation?
    private var session: URLSession?

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        Task { [weak self] in await self?.readLoop() }
    }

    func stop() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func send(_ data: Data) async throws {
        guard let task else { throw CDPError.transportNotStarted }
        try await task.send(.data(data))
    }

    func makeIncoming() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    private func readLoop() async {
        while let task {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let d):
                    continuation?.yield(d)
                case .string(let s):
                    continuation?.yield(Data(s.utf8))
                @unknown default:
                    continue
                }
            } catch {
                continuation?.finish()
                continuation = nil
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
