# browserCDP Phase 2 Implementation Plan (Park MVP)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` syntax.

**Goal:** Ship the smallest Park+Follow slice of Phase 2: a CDP WebSocket client in Swift and a Debug-menu button that tells the launched Chromium to move its window to match cmux's main window bounds. This validates the CDP client + `Browser.setWindowBounds` round-trip end-to-end. Panel type, AXObserver drag-resync, Space tracking, and follower child-window visual fidelity are **deferred to Phase 2b**.

**Architecture:** A tiny async JSON-RPC 2.0 client over `URLSessionWebSocketTask`, abstracted behind a `CDPTransport` protocol for unit testability. A thin `ChromiumCDPClient` layer on top provides typed helpers (`browserGetWindowForTarget`, `browserSetWindowBounds`). `BrowserCDPDebugLauncher` stores the client alongside the manager and gains a `moveToCmuxMainWindow()` entry point.

**Tech Stack:** Swift concurrency (async/await), `URLSessionWebSocketTask`, `JSONSerialization`, XCTest.

---

## Files

- Create: `Sources/Panels/BrowserCDPLaunch/CDPTransport.swift`
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumCDPClient.swift`
- Create: `cmuxTests/ChromiumCDPClientTests.swift`
- Modify: `Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift`
- Modify: `Sources/cmuxApp.swift` — add second Debug menu button
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj` — wire 2 new sources + 1 test

---

## Task 1: CDPTransport protocol + WebSocket implementation

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/CDPTransport.swift`

- [ ] **Step 1: Write the file**

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/CDPTransport.swift
git commit -m "Add CDPTransport protocol + URLSession WebSocket impl"
```

---

## Task 2: Failing ChromiumCDPClient tests

**Files:**
- Test: `cmuxTests/ChromiumCDPClientTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import cmux

final class ChromiumCDPClientTests: XCTestCase {

    private final class FakeTransport: CDPTransport {
        var sent: [Data] = []
        private var continuation: AsyncStream<Data>.Continuation?

        func start() async throws {}
        func stop() { continuation?.finish() }
        func send(_ data: Data) async throws { sent.append(data) }
        func makeIncoming() -> AsyncStream<Data> {
            AsyncStream { self.continuation = $0 }
        }

        func deliver(_ json: String) {
            continuation?.yield(Data(json.utf8))
        }
    }

    func test_sendReturnsMatchingResponse() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let resultTask = Task<[String: Any], Error> {
            try await client.send(method: "Target.getTargets", params: [:])
        }

        // Wait for the client to flush its send.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        let id = sentJSON["id"] as! Int
        XCTAssertEqual(sentJSON["method"] as? String, "Target.getTargets")

        transport.deliver("""
        {"id":\(id),"result":{"targetInfos":[{"targetId":"t-1","type":"page"}]}}
        """)

        let result = try await resultTask.value
        let infos = result["targetInfos"] as? [[String: Any]]
        XCTAssertEqual(infos?.first?["targetId"] as? String, "t-1")
    }

    func test_remoteErrorPropagates() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let resultTask = Task<[String: Any], Error> {
            try await client.send(method: "Browser.setWindowBounds", params: [:])
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        let id = sentJSON["id"] as! Int

        transport.deliver("""
        {"id":\(id),"error":{"code":-32602,"message":"invalid params"}}
        """)

        do {
            _ = try await resultTask.value
            XCTFail("expected error")
        } catch CDPError.remote(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "invalid params")
        }
    }

    func test_multipleInflightRequestsMatchByID() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        async let a = client.send(method: "Target.getTargets", params: [:])
        async let b = client.send(method: "Browser.getVersion", params: [:])

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 2)
        let ids = try transport.sent.map { data -> Int in
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return obj["id"] as! Int
        }
        // Deliver responses out of order.
        transport.deliver("""
        {"id":\(ids[1]),"result":{"product":"HeadlessChrome"}}
        """)
        transport.deliver("""
        {"id":\(ids[0]),"result":{"targetInfos":[]}}
        """)

        let (resA, resB) = try await (a, b)
        XCTAssertNotNil(resA["targetInfos"])
        XCTAssertEqual(resB["product"] as? String, "HeadlessChrome")
    }

    func test_browserSetWindowBoundsHelperShape() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let task = Task {
            try await client.browserSetWindowBounds(
                windowId: 42,
                bounds: .init(left: 100, top: 200, width: 800, height: 600)
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        XCTAssertEqual(sentJSON["method"] as? String, "Browser.setWindowBounds")
        let params = sentJSON["params"] as! [String: Any]
        XCTAssertEqual(params["windowId"] as? Int, 42)
        let bounds = params["bounds"] as! [String: Any]
        XCTAssertEqual(bounds["left"] as? Int, 100)
        XCTAssertEqual(bounds["top"] as? Int, 200)
        XCTAssertEqual(bounds["width"] as? Int, 800)
        XCTAssertEqual(bounds["height"] as? Int, 600)

        let id = sentJSON["id"] as! Int
        transport.deliver("{\"id\":\(id),\"result\":{}}")
        try await task.value
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add cmuxTests/ChromiumCDPClientTests.swift
git commit -m "Add failing ChromiumCDPClient tests"
```

---

## Task 3: ChromiumCDPClient implementation

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumCDPClient.swift`

- [ ] **Step 1: Write the file**

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/ChromiumCDPClient.swift
git commit -m "Add ChromiumCDPClient JSON-RPC layer + Browser.setWindowBounds helper"
```

---

## Task 4: Extend BrowserCDPDebugLauncher + Debug menu

**Files:**
- Modify: `Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift`
- Modify: `Sources/cmuxApp.swift` — add a second Debug Windows menu button

- [ ] **Step 1: Rewrite BrowserCDPDebugLauncher.swift**

Replace the file with:

```swift
#if DEBUG
import AppKit
import Bonsplit

@MainActor
enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?
    private static var client: ChromiumCDPClient?
    private static var observerInstalled = false

    static func launchAndReportURL() async {
        installTerminateObserverIfNeeded()
        let locator = ChromiumBinaryLocator()
        let binary: ChromiumBinary
        do {
            binary = try locator.locate()
        } catch {
            dlog("browserCDP: locate failed: \(error)")
            presentAlert(title: "Chromium not found",
                         body: "Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`.")
            return
        }
        dlog("browserCDP: using \(binary.source.rawValue) at \(binary.path)")

        manager?.terminate()
        client?.close()
        client = nil

        let mgr = ChromiumLaunchManager(binary: binary)
        manager = mgr
        mgr.launch(initialURL: URL(string: "about:blank"), timeout: 15) { result in
            Task { @MainActor in
                switch result {
                case .success(let endpoint):
                    let url = endpoint.webSocketURL.absoluteString
                    dlog("browserCDP: \(url)")
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url, forType: .string)

                    let transport = CDPWebSocketTransport(url: endpoint.webSocketURL)
                    let cdp = ChromiumCDPClient(transport: transport)
                    client = cdp
                    do {
                        try await cdp.connect()
                    } catch {
                        dlog("browserCDP: CDP connect failed: \(error)")
                    }

                    presentAlert(title: "Chromium launched",
                                 body: "CDP URL copied to clipboard:\n\(url)")
                case .failure(let error):
                    dlog("browserCDP: launch failed: \(error)")
                    presentAlert(title: "Chromium launch failed",
                                 body: "\(error)")
                }
            }
        }
    }

    static func moveChromiumToCmuxMainWindow() async {
        guard let cdp = client else {
            presentAlert(title: "No Chromium running",
                         body: "Use “Launch Chromium (CDP)…” first.")
            return
        }
        guard let screenRect = cmuxMainWindowScreenRect() else {
            presentAlert(title: "No cmux window",
                         body: "Bring a cmux window to the foreground first.")
            return
        }
        do {
            guard let targetId = try await cdp.firstPageTargetId() else {
                presentAlert(title: "No Chromium page",
                             body: "CDP reports no page target.")
                return
            }
            let windowId = try await cdp.browserGetWindowForTarget(targetId: targetId)
            try await cdp.browserSetWindowBounds(
                windowId: windowId,
                bounds: .init(
                    left: Int(screenRect.origin.x),
                    top: Int(screenRect.origin.y),
                    width: Int(screenRect.size.width),
                    height: Int(screenRect.size.height)
                )
            )
            dlog("browserCDP: moved Chromium to \(screenRect)")
        } catch {
            dlog("browserCDP: setWindowBounds failed: \(error)")
            presentAlert(title: "Move failed", body: "\(error)")
        }
    }

    /// CDP `Browser.setWindowBounds` uses top-origin screen coordinates (y grows
    /// downward, origin at the primary display's top-left). NSWindow.frame uses
    /// bottom-origin coordinates (y grows upward, origin at the primary
    /// display's bottom-left). Convert NSWindow.frame → CDP coords here.
    private static func cmuxMainWindowScreenRect() -> CGRect? {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return nil
        }
        guard let primaryScreen = NSScreen.screens.first else {
            return window.frame
        }
        let primaryHeight = primaryScreen.frame.size.height
        let frame = window.frame
        let topY = primaryHeight - (frame.origin.y + frame.size.height)
        return CGRect(x: frame.origin.x, y: topY, width: frame.size.width, height: frame.size.height)
    }

    private static func installTerminateObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                client?.close()
                client = nil
                manager?.terminate()
                manager = nil
            }
        }
    }

    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
```

- [ ] **Step 2: Add the second Debug menu button**

In `Sources/cmuxApp.swift`, find:

```swift
                    Button("Launch Chromium (CDP)…") {
                        Task.detached { await BrowserCDPDebugLauncher.launchAndReportURL() }
                    }
                    Button("Menu Bar Extra Debug…") {
```

Insert a second button between them:

```swift
                    Button("Launch Chromium (CDP)…") {
                        Task.detached { await BrowserCDPDebugLauncher.launchAndReportURL() }
                    }
                    Button("Move Chromium to cmux Window") {
                        Task.detached { await BrowserCDPDebugLauncher.moveChromiumToCmuxMainWindow() }
                    }
                    Button("Menu Bar Extra Debug…") {
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift Sources/cmuxApp.swift
git commit -m "Wire Chromium CDP client into Debug launcher; add move-window menu button"
```

---

## Task 5: Xcode project wiring

**Files:**
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

Add 2 new sources (CDPTransport.swift, ChromiumCDPClient.swift) and 1 new test (ChromiumCDPClientTests.swift) using IDs `BC11000009`/`BC22000009`, `BC1100000A`/`BC2200000A`, `BC1100000B`/`BC2200000B` (all unique — verify with `grep -c "BC11000009\|BC22000009\|BC1100000A\|BC2200000A\|BC1100000B\|BC2200000B" GhosttyTabs.xcodeproj/project.pbxproj` returns 0 before editing).

- [ ] **Step 1: Six pbxproj edits**

Follow the exact pattern from the Phase 1 wiring commit `a6dd8f6c`:

1. **PBXBuildFile** — after the last `BC11000008` line:
   ```
   		BC11000009 /* CDPTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = BC22000009 /* CDPTransport.swift */; };
   		BC1100000A /* ChromiumCDPClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = BC2200000A /* ChromiumCDPClient.swift */; };
   		BC1100000B /* ChromiumCDPClientTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BC2200000B /* ChromiumCDPClientTests.swift */; };
   ```

2. **PBXFileReference** — after the last `BC22000008` line:
   ```
   		BC22000009 /* CDPTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Panels/BrowserCDPLaunch/CDPTransport.swift; sourceTree = "<group>"; };
   		BC2200000A /* ChromiumCDPClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Panels/BrowserCDPLaunch/ChromiumCDPClient.swift; sourceTree = "<group>"; };
   		BC2200000B /* ChromiumCDPClientTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ChromiumCDPClientTests.swift; sourceTree = "<group>"; };
   ```

3. **Panels group children** — after `BC22000008 /* BrowserCDPDebugLauncher.swift */,`:
   ```
   				BC22000009 /* CDPTransport.swift */,
   				BC2200000A /* ChromiumCDPClient.swift */,
   ```

4. **cmuxTests group children** — after `BC22000007 /* ChromiumLaunchManagerTests.swift */,`:
   ```
   					BC2200000B /* ChromiumCDPClientTests.swift */,
   ```

5. **GhosttyTabs target Sources build phase** — after `BC11000008 /* BrowserCDPDebugLauncher.swift in Sources */,`:
   ```
   				BC11000009 /* CDPTransport.swift in Sources */,
   				BC1100000A /* ChromiumCDPClient.swift in Sources */,
   ```

6. **cmuxTests target Sources build phase** — after `BC11000007 /* ChromiumLaunchManagerTests.swift in Sources */,`:
   ```
   					BC1100000B /* ChromiumCDPClientTests.swift in Sources */,
   ```

- [ ] **Step 2: Verify**

```bash
plutil -lint GhosttyTabs.xcodeproj/project.pbxproj
```

Expected: OK. (Local xcodebuild can't run in this environment; rely on CI.)

- [ ] **Step 3: Commit**

```bash
git add GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Wire CDP client + test into cmux + cmuxTests targets"
```

---

## Task 6: Update docs

**Files:**
- Modify: `docs/playwright-headful.md`

- [ ] **Step 1: Add a phase 2 section**

Edit the file to add this section immediately before the "Known limitations (phase 1)" heading, and update the status banner at the top:

```markdown
## Phase 2 (park): Debug-menu "Move Chromium to cmux Window"

Phase 2 adds a CDP client to cmux and a second Debug menu entry:

`Debug → Debug Windows → Move Chromium to cmux Window`

After launching Chromium via the phase 1 button, click "Move Chromium to
cmux Window" to tell Chromium (via `Browser.setWindowBounds`) to occupy the
cmux main window's screen rect. Chromium remains a real NSWindow in its
own process — native cursor, IME, and scrolling all work — but its rect
is driven by cmux.

Phase 2b will follow the cmux panel's NSView frame live (not just on
button click) and re-assert the rect when the user drags Chromium.
```

Also change the status banner at the top from "Phase 1 status: ... The Chromium window is separate from the cmux window. Phase 2 will embed it into a cmux panel." to:

```markdown
> Phase 2 status: cmux launches Chromium and can drive its screen rect via
> CDP Browser.setWindowBounds. The Chromium window is still its own
> NSWindow (not reparented) — we coordinate its bounds instead of
> embedding pixels. Phase 2b will auto-follow the cmux panel's rect.
```

- [ ] **Step 2: Commit**

```bash
git add docs/playwright-headful.md
git commit -m "Document phase 2 move-Chromium Debug workflow"
```

---

## Verification summary

- [ ] `plutil -lint GhosttyTabs.xcodeproj/project.pbxproj` → OK
- [ ] Syntax parse of the two new Swift files succeeds (via CommandLineTools swiftc `-parse`).
- [ ] CI (`test-e2e.yml` + unit tests) passes after push.
- [ ] Manual verification (user's working Xcode): launch Chromium from Debug menu, click "Move Chromium to cmux Window" — Chromium snaps to the cmux main window rect.

## Deferred to Phase 2b / Phase 3

- `BrowserCDPPanel` / `BrowserCDPPanelView` type in the panel system.
- Live rect following on cmux panel frame changes (NSView frame KVO → setWindowBounds debounced).
- `AXObserver` on Chromium PID → reassert rect on user drag.
- `NSWorkspace.activeSpaceDidChangeNotification` → follow spaces.
- Session persistence for BrowserCDP panels.
- Follower child-NSWindow for visual containment.
- `browser.cdp.*` socket API + `cmux browser cdp-url` CLI.
- SCStream fallback for occluded / background / preview rendering.
