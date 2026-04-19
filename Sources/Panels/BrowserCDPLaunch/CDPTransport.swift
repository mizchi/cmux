import Foundation
import Network
#if DEBUG
import Bonsplit
#endif

/// Byte-stream transport for CDP's JSON-RPC frames. Abstracted behind a
/// protocol so `ChromiumCDPClient` can be unit-tested against a
/// FakeTransport without a real WebSocket.
protocol CDPTransport: AnyObject {
    func start() async throws
    func stop()
    func send(_ data: Data) async throws
    /// The incoming stream is built eagerly by `start()`. Call this
    /// exactly once per transport lifetime to hand it to the consumer.
    func makeIncoming() -> AsyncStream<Data>
}

/// WebSocket transport built on `Network.framework`'s `NWConnection`.
/// Chosen over `URLSessionWebSocketTask` because the latter silently
/// hangs against Chromium's CDP endpoint: URLSession requests
/// `Sec-WebSocket-Extensions: permessage-deflate` in its handshake and
/// Chromium's remote-debugging server drops every subsequent frame.
/// `NWProtocolWebSocket` does not request extensions by default, which
/// Chromium accepts without issue.
final class CDPWebSocketTransport: CDPTransport {
    private let url: URL
    private let lock = NSLock()
    private var connection: NWConnection?
    private var stream: AsyncStream<Data>?
    private var continuation: AsyncStream<Data>.Continuation?
    private var incomingDelivered = false
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private let queue = DispatchQueue(label: "cmux.chromium.cdp.ws")

    init(url: URL) {
        self.url = url
    }

    // MARK: - CDPTransport

    func start() async throws {
        guard url.host != nil, url.port != nil else {
            throw CDPError.transportNotStarted
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        withLock {
            self.stream = stream
            self.continuation = continuation
        }

        let connection = NWConnection(to: .url(url), using: Self.wsParameters(url: url))
        withLock { self.connection = connection }

        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        connection.start(queue: queue)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            withLock { handshakeContinuation = cont }
        }
    }

    func stop() {
        let (connection, streamCont) = withLock { () -> (NWConnection?, AsyncStream<Data>.Continuation?) in
            let c = self.connection
            let s = self.continuation
            self.connection = nil
            self.continuation = nil
            return (c, s)
        }
        connection?.cancel()
        streamCont?.finish()
    }

    func send(_ data: Data) async throws {
        let connection = withLock { self.connection }
        guard let connection else { throw CDPError.transportNotStarted }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "cdp", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    error.map { cont.resume(throwing: $0) } ?? cont.resume()
                }
            )
        }
    }

    func makeIncoming() -> AsyncStream<Data> {
        withLock {
            precondition(!incomingDelivered, "CDPWebSocketTransport.makeIncoming called twice")
            guard let stream else {
                preconditionFailure("CDPWebSocketTransport.makeIncoming called before start()")
            }
            incomingDelivered = true
            return stream
        }
    }

    // MARK: - State + receive

    private func handle(state: NWConnection.State) {
        #if DEBUG
        dlog("CDP ws state: \(state)")
        #endif
        switch state {
        case .ready:
            let cont = withLock { () -> CheckedContinuation<Void, Error>? in
                let c = handshakeContinuation
                handshakeContinuation = nil
                return c
            }
            cont?.resume()
            receiveLoop()

        case .failed(let error):
            finishStream(with: error)

        case .cancelled:
            finishStream(with: nil)

        default:
            break
        }
    }

    private func receiveLoop() {
        let connection = withLock { self.connection }
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                #if DEBUG
                dlog("CDP ws recv error: \(error)")
                #endif
                self.finishStream(with: error)
                return
            }
            if let data, !data.isEmpty {
                self.withLock { self.continuation }?.yield(data)
            }
            if isComplete {
                self.receiveLoop()
            }
        }
    }

    /// Release both the handshake waiter (if still pending) and the
    /// incoming stream. Safe to call multiple times — idempotent.
    private func finishStream(with error: Error?) {
        let (handshake, streamCont) = withLock { () -> (CheckedContinuation<Void, Error>?, AsyncStream<Data>.Continuation?) in
            let h = handshakeContinuation
            handshakeContinuation = nil
            let s = self.continuation
            self.continuation = nil
            return (h, s)
        }
        if let error {
            handshake?.resume(throwing: error)
        } else {
            handshake?.resume(throwing: CDPError.transportNotStarted)
        }
        streamCont?.finish()
    }

    // MARK: - Helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// WS handshake parameters: set `Origin` explicitly — Chromium 147+
    /// enforces `--remote-allow-origins` and refuses upgrades whose
    /// request has no `Origin` header (even when the flag is `*`).
    private static func wsParameters(url: URL) -> NWParameters {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let origin = "http://\(url.host ?? "127.0.0.1"):\(url.port ?? 0)"
        wsOptions.setAdditionalHeaders([("Origin", origin)])

        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return params
    }
}

enum CDPError: Error, CustomStringConvertible {
    case transportNotStarted
    case notConnected
    case malformedResponse(String)
    case remote(code: Int, message: String)

    var description: String {
        switch self {
        case .transportNotStarted: return "CDP transport not started"
        case .notConnected: return "CDP client not connected"
        case .malformedResponse(let s): return "Malformed CDP response: \(s)"
        case .remote(let code, let message): return "CDP error \(code): \(message)"
        }
    }
}
