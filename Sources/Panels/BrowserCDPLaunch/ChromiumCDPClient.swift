import Foundation

/// Thin JSON-RPC 2.0 client over a CDPTransport. Actor-isolated so
/// multiple tasks can await send(...) concurrently without stepping on
/// the in-flight table.
actor ChromiumCDPClient {
    private let transport: CDPTransport
    private var nextId: Int = 1
    private var inflight: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventTask: Task<Void, Never>?
    private var connected = false

    init(transport: CDPTransport) {
        self.transport = transport
    }

    func connect() async throws {
        guard !connected else { return }
        try await transport.start()
        connected = true
        let incoming = transport.makeIncoming()
        eventTask = Task { [weak self] in
            for await data in incoming {
                await self?.handleIncoming(data)
            }
        }
    }

    func close() {
        connected = false
        transport.stop()
        eventTask?.cancel()
        eventTask = nil
        for (_, cont) in inflight {
            cont.resume(throwing: CDPError.notConnected)
        }
        inflight.removeAll()
    }

    @discardableResult
    func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard connected else { throw CDPError.notConnected }
        let id = nextId
        nextId += 1
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            inflight[id] = cont
            Task {
                do {
                    try await transport.send(data)
                } catch {
                    if let c = inflight.removeValue(forKey: id) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let id = obj["id"] as? Int, let cont = inflight.removeValue(forKey: id) {
            if let error = obj["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "(no message)"
                cont.resume(throwing: CDPError.remote(code: code, message: message))
            } else {
                let result = obj["result"] as? [String: Any] ?? [:]
                cont.resume(returning: result)
            }
        }
        // Events (no id) are ignored in Phase 2 MVP. Phase 2b will surface them.
    }
}

extension ChromiumCDPClient {
    struct WindowBounds: Equatable {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
    }

    @discardableResult
    func browserGetWindowForTarget(targetId: String) async throws -> Int {
        let result = try await send(method: "Browser.getWindowForTarget", params: ["targetId": targetId])
        guard let windowId = result["windowId"] as? Int else {
            throw CDPError.malformedResponse("Browser.getWindowForTarget missing windowId")
        }
        return windowId
    }

    func browserSetWindowBounds(windowId: Int, bounds: WindowBounds) async throws {
        _ = try await send(method: "Browser.setWindowBounds", params: [
            "windowId": windowId,
            "bounds": [
                "left": bounds.left,
                "top": bounds.top,
                "width": bounds.width,
                "height": bounds.height,
            ],
        ])
    }

    /// Returns the first page-type target, or nil.
    func firstPageTargetId() async throws -> String? {
        let result = try await send(method: "Target.getTargets", params: [:])
        guard let infos = result["targetInfos"] as? [[String: Any]] else { return nil }
        for info in infos {
            if info["type"] as? String == "page", let id = info["targetId"] as? String {
                return id
            }
        }
        return nil
    }
}
