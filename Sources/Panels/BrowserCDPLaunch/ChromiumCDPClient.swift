import Foundation
#if DEBUG
import Bonsplit
#endif

/// Thin JSON-RPC 2.0 client over a CDPTransport. Actor-isolated so
/// multiple tasks can await send(...) concurrently without stepping on
/// the in-flight table.
actor ChromiumCDPClient {
    private let transport: CDPTransport
    private var nextId: Int = 1
    private var inflight: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventTask: Task<Void, Never>?
    private var connected = false
    /// Delivered on the actor's executor for every CDP event (frames with
    /// no `id`). Method name, params dict, and optional sessionId.
    var eventHandler: ((String, [String: Any], String?) -> Void)?

    init(transport: CDPTransport) {
        self.transport = transport
    }

    func setEventHandler(_ handler: ((String, [String: Any], String?) -> Void)?) {
        eventHandler = handler
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
    func send(method: String, params: [String: Any], sessionId: String? = nil) async throws -> [String: Any] {
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

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            inflight[id] = cont
            Task {
                do {
                    #if DEBUG
                    dlog("CDP>> id=\(id) method=\(method) sid=\(sessionId ?? "-")")
                    #endif
                    try await transport.send(data)
                } catch {
                    #if DEBUG
                    dlog("CDP>> send error id=\(id): \(error)")
                    #endif
                    if let c = inflight.removeValue(forKey: id) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        #if DEBUG
        // Swift-log-sized preview so we can confirm frames flow.
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        dlog("CDP<< \(preview)")
        #endif
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
            return
        }
        // Event (no id): forward to the event handler if any.
        if let method = obj["method"] as? String {
            let params = (obj["params"] as? [String: Any]) ?? [:]
            let sessionId = obj["sessionId"] as? String
            eventHandler?(method, params, sessionId)
        }
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

    /// Attach a flattened session to a target. Required before sending
    /// Page.* / Runtime.* commands against a specific tab via the
    /// browser-level connection.
    func targetAttach(targetId: String) async throws -> String {
        let result = try await send(method: "Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true,
        ])
        guard let sessionId = result["sessionId"] as? String else {
            throw CDPError.malformedResponse("Target.attachToTarget missing sessionId")
        }
        return sessionId
    }

    /// Attach (creating a session if needed) and issue Page.navigate.
    /// Returns the page target id + attached sessionId for reuse.
    @discardableResult
    func pageNavigate(targetId: String, sessionId: String? = nil, url: String) async throws -> (targetId: String, sessionId: String) {
        let sid: String
        if let sessionId { sid = sessionId } else { sid = try await targetAttach(targetId: targetId) }
        _ = try await send(method: "Page.navigate", params: ["url": url], sessionId: sid)
        return (targetId, sid)
    }

    func pageReload(sessionId: String) async throws {
        _ = try await send(method: "Page.reload", params: [:], sessionId: sessionId)
    }

    /// CDP's Page domain has no back/forward convenience methods across
    /// versions; use Runtime.evaluate to drive window.history instead.
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

    /// Page.enable on a session so Page events (screencastFrame etc.) fire.
    func pageEnable(sessionId: String) async throws {
        _ = try await send(method: "Page.enable", params: [:], sessionId: sessionId)
    }

    /// Begin streaming per-frame screenshots of the rendered page. Emits
    /// `Page.screencastFrame` events each with a base64 JPEG payload.
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
        _ = try await send(method: "Page.screencastFrameAck", params: [
            "sessionId": frameSessionId,
        ], sessionId: sessionId)
    }

    /// Override the rendered viewport. Used to make Chromium's page size
    /// match the cmux panel exactly so captured frames are 1:1.
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

    func emulationClearDeviceMetricsOverride(sessionId: String) async throws {
        _ = try await send(method: "Emulation.clearDeviceMetricsOverride", params: [:], sessionId: sessionId)
    }
}
