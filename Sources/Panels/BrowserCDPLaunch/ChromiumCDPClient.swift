import Foundation

/// JSON-RPC 2.0 client over a `CDPTransport`. Actor-isolated so
/// concurrent `send(...)` calls can share the in-flight table safely.
///
/// Domain-specific helpers (Target / Page / Emulation / etc.) live in
/// this file's extension block. Command methods prefix their names
/// with the CDP domain (e.g. `pageNavigate`) and take a session id
/// when the command requires one.
actor ChromiumCDPClient {
    private let transport: CDPTransport
    private var nextId: Int = 1
    private var inflight: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventTask: Task<Void, Never>?
    private var connected = false
    /// Called for every CDP event (no `id`). Method name, params, and
    /// optional session id. Delivered on the actor's executor.
    private var eventHandler: ((String, [String: Any], String?) -> Void)?

    init(transport: CDPTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    func connect() async throws {
        guard !connected else { return }
        try await transport.start()
        connected = true
        let incoming = transport.makeIncoming()
        eventTask = Task { [weak self] in
            for await data in incoming { await self?.handleIncoming(data) }
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

    func setEventHandler(_ handler: ((String, [String: Any], String?) -> Void)?) {
        eventHandler = handler
    }

    // MARK: - Send / receive

    @discardableResult
    func send(
        method: String,
        params: [String: Any],
        sessionId: String? = nil
    ) async throws -> [String: Any] {
        guard connected else { throw CDPError.notConnected }
        let id = nextId
        nextId += 1
        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        if let sessionId { payload["sessionId"] = sessionId }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        return try await withCheckedThrowingContinuation { cont in
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
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
            return
        }
        if let method = obj["method"] as? String {
            let params = (obj["params"] as? [String: Any]) ?? [:]
            let sessionId = obj["sessionId"] as? String
            eventHandler?(method, params, sessionId)
        }
    }
}

// MARK: - CDP command helpers

extension ChromiumCDPClient {
    /// First target of `type == "page"`, or nil.
    func firstPageTargetId() async throws -> String? {
        let result = try await send(method: "Target.getTargets", params: [:])
        guard let infos = result["targetInfos"] as? [[String: Any]] else { return nil }
        return infos
            .first { ($0["type"] as? String) == "page" }
            .flatMap { $0["targetId"] as? String }
    }

    /// Attach a flat session to `targetId`. Required before any Page.* /
    /// Runtime.* / Emulation.* call on a specific page.
    func targetAttach(targetId: String) async throws -> String {
        let result = try await send(method: "Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true,
        ])
        guard let sid = result["sessionId"] as? String else {
            throw CDPError.malformedResponse("Target.attachToTarget missing sessionId")
        }
        return sid
    }

    @discardableResult
    func pageNavigate(
        targetId: String,
        sessionId: String? = nil,
        url: String
    ) async throws -> (targetId: String, sessionId: String) {
        let sid: String
        if let sessionId {
            sid = sessionId
        } else {
            sid = try await targetAttach(targetId: targetId)
        }
        _ = try await send(method: "Page.navigate", params: ["url": url], sessionId: sid)
        return (targetId, sid)
    }

    func pageReload(sessionId: String) async throws {
        _ = try await send(method: "Page.reload", params: [:], sessionId: sessionId)
    }

    /// CDP's Page domain has no cross-version back / forward helpers;
    /// drive `window.history` via `Runtime.evaluate` instead.
    func pageGoBack(sessionId: String) async throws {
        _ = try await send(method: "Runtime.evaluate", params: [
            "expression": "history.back()",
            "awaitPromise": false,
        ], sessionId: sessionId)
    }

    func pageGoForward(sessionId: String) async throws {
        _ = try await send(method: "Runtime.evaluate", params: [
            "expression": "history.forward()",
            "awaitPromise": false,
        ], sessionId: sessionId)
    }

    /// Enable Page events (screencastFrame etc.) for a session.
    func pageEnable(sessionId: String) async throws {
        _ = try await send(method: "Page.enable", params: [:], sessionId: sessionId)
    }

    /// Start streaming per-frame page screenshots as base64 JPEG.
    func pageStartScreencast(
        sessionId: String,
        format: String = "jpeg",
        quality: Int = 80,
        maxWidth: Int,
        maxHeight: Int,
        everyNthFrame: Int = 1
    ) async throws {
        _ = try await send(method: "Page.startScreencast", params: [
            "format": format,
            "quality": quality,
            "maxWidth": maxWidth,
            "maxHeight": maxHeight,
            "everyNthFrame": everyNthFrame,
        ], sessionId: sessionId)
    }

    func pageStopScreencast(sessionId: String) async throws {
        _ = try await send(method: "Page.stopScreencast", params: [:], sessionId: sessionId)
    }

    func pageScreencastFrameAck(sessionId: String, frameSessionId: Int) async throws {
        _ = try await send(
            method: "Page.screencastFrameAck",
            params: ["sessionId": frameSessionId],
            sessionId: sessionId
        )
    }

    /// Resize Chromium's rendered viewport. Used by the panel to keep
    /// the screencast's rendered buffer 1:1 with the panel's NSView.
    func emulationSetDeviceMetricsOverride(
        sessionId: String,
        width: Int,
        height: Int,
        deviceScaleFactor: Double = 2.0,
        mobile: Bool = false
    ) async throws {
        _ = try await send(method: "Emulation.setDeviceMetricsOverride", params: [
            "width": width,
            "height": height,
            "deviceScaleFactor": deviceScaleFactor,
            "mobile": mobile,
        ], sessionId: sessionId)
    }
}
