import Foundation
import Network
#if DEBUG
import Bonsplit
#endif

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

/// WebSocket transport built on Network.framework's NWConnection. Used
/// instead of URLSessionWebSocketTask because the latter silently hangs
/// against Chromium's CDP endpoint — Chromium's remote-debugging server
/// disagrees with one of URLSession's default negotiation headers
/// (most likely `Sec-WebSocket-Extensions: permessage-deflate`) and
/// closes the socket right after handshake completion. NWProtocolWebSocket
/// does not request extensions by default, which Chromium accepts.
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

    func start() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.lock()
        self.stream = stream
        self.continuation = continuation
        lock.unlock()

        guard let host = url.host, let port = url.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw CDPError.transportNotStarted
        }
        let nwHost = NWEndpoint.Host(host)
        let path = url.path.isEmpty ? "/" : url.path

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // Chromium 147+ requires `Origin` to be present for the WS upgrade
        // when --remote-allow-origins is specified (even `*`). Synthesise
        // one from the CDP endpoint itself.
        let origin = "http://\(host):\(port)"
        wsOptions.setAdditionalHeaders([
            ("Origin", origin),
            ("Host", "\(host):\(port)"),
        ])

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // NWConnection dials the host:port and walks the WS upgrade; path
        // comes from the URL's absolute request line which NWProtocolWebSocket
        // derives from the supplied host + the connection's metadata.
        // `NWEndpoint.url` is the cleanest way to carry the path.
        let endpoint: NWEndpoint = .url(url)
        _ = nwHost
        _ = nwPort
        _ = path

        let connection = NWConnection(to: endpoint, using: parameters)
        lock.lock()
        self.connection = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            #if DEBUG
            dlog("CDP ws state: \(state)")
            #endif
            switch state {
            case .ready:
                self.lock.lock()
                let cont = self.handshakeContinuation
                self.handshakeContinuation = nil
                self.lock.unlock()
                cont?.resume()
                self.receiveLoop()
            case .failed(let error):
                self.lock.lock()
                let cont = self.handshakeContinuation
                self.handshakeContinuation = nil
                let streamCont = self.continuation
                self.continuation = nil
                self.lock.unlock()
                cont?.resume(throwing: error)
                streamCont?.finish()
            case .cancelled:
                self.lock.lock()
                let streamCont = self.continuation
                self.continuation = nil
                self.lock.unlock()
                streamCont?.finish()
            default:
                break
            }
        }

        connection.start(queue: queue)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            handshakeContinuation = cont
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let connection = self.connection
        let continuation = self.continuation
        self.connection = nil
        self.continuation = nil
        lock.unlock()
        connection?.cancel()
        continuation?.finish()
    }

    func send(_ data: Data) async throws {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { throw CDPError.transportNotStarted }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "cdp", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            )
        }
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

    private func receiveLoop() {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                #if DEBUG
                dlog("CDP ws recv error: \(error)")
                #endif
                self.lock.lock()
                let streamCont = self.continuation
                self.continuation = nil
                self.lock.unlock()
                streamCont?.finish()
                return
            }
            if let data, !data.isEmpty {
                self.lock.lock()
                let streamCont = self.continuation
                self.lock.unlock()
                streamCont?.yield(data)
            }
            if isComplete {
                self.receiveLoop()
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
