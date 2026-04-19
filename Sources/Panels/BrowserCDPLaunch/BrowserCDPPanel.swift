import Foundation
import Combine
import AppKit
#if DEBUG
import Bonsplit
#endif

/// Panel that hosts a CDP-driven Chromium window. Phase 2 MVP: each panel
/// owns one Chromium subprocess launched with --remote-debugging-port, and
/// drives its screen rect via CDP Browser.setWindowBounds whenever the panel
/// view's on-screen frame changes.
///
/// Chromium remains its own NSWindow in its own process — cmux does not
/// embed pixels. The panel reserves a rect and asks Chromium to match it.
@MainActor
final class BrowserCDPPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .browserCDP

    @Published private(set) var displayTitle: String = String(
        localized: "browserCDP.panel.tabTitle",
        defaultValue: "Chromium"
    )
    var displayIcon: String? { "globe" }
    @Published private(set) var focusFlashToken: Int = 0

    /// Current CDP endpoint once the subprocess is up. Nil while launching or on failure.
    @Published private(set) var endpoint: ChromiumDevToolsEndpoint?
    @Published private(set) var statusMessage: String = String(
        localized: "browserCDP.panel.status.launching",
        defaultValue: "Launching Chromium…"
    )

    /// The current navigation URL, kept in sync when the user issues
    /// `navigate(_:)`. Serves as the initial text for the address bar
    /// in the panel view.
    @Published var currentURL: String = "about:blank"

    private let manager: ChromiumLaunchManager
    private var client: ChromiumCDPClient?
    private var axObserver: ChromiumAXObserver?
    private var cachedWindowId: Int?
    private var cachedPageTargetId: String?
    private var cachedPageSessionId: String?
    private var pendingBoundsPush: DispatchWorkItem?
    private var isClosed = false
    /// Remembered even while the CDP client is still connecting, so we can
    /// replay the first known rect as soon as the client comes up.
    private var lastRequestedRect: CGRect?
    /// Tracks whether Chromium has exited externally; surfaces as a Relaunch
    /// button in the view.
    @Published private(set) var isChromiumExited: Bool = false

    /// Phase 3b opt-in: when true, the panel view renders Chromium pixels
    /// directly via ScreenCaptureKit and routes mouse/key input via CDP
    /// Input.dispatch*. When false (default) the park path is used.
    @Published private(set) var captureMode: Bool = false

    /// Storage for the capture stream. Kept type-erased to avoid
    /// sprinkling @available guards through the class; the stored value
    /// is always an `AnyObject?` that downcasts to
    /// `ChromiumScreenCaptureStream` when the macOS version supports it.
    private var captureStreamStorage: AnyObject?
    /// Exposed to BrowserCDPPanelView for rendering. Nil on macOS < 12.3.
    @available(macOS 12.3, *)
    var captureStream: ChromiumScreenCaptureStream? {
        captureStreamStorage as? ChromiumScreenCaptureStream
    }
    /// Non-nil while capture mode is active and the CDP client is ready.
    /// Exposed to the view so mouse / key events can route through it.
    private(set) var inputRouter: ChromiumCDPInputRouter?

    private static let debounceMs: Int = 16
    /// Cooldown between user-drag detection and next snap-back push, so
    /// we don't fight a live drag (Chromium emits AX events continuously
    /// during the drag). 180ms is long enough to wait for the user to let
    /// go of the title bar.
    private static let axReassertDelayMs: Int = 180

    init() {
        self.id = UUID()
        let locator = ChromiumBinaryLocator()
        do {
            let binary = try locator.locate()
            self.manager = ChromiumLaunchManager(binary: binary)
            manager.onProcessExit = { [weak self] in
                self?.handleChromiumExited()
            }
            launch()
        } catch {
            // Initialize with an unusable manager; we report the error via status.
            self.manager = ChromiumLaunchManager(
                binary: ChromiumBinary(path: "/dev/null", source: .envOverride)
            )
            self.statusMessage = String(
                localized: "browserCDP.panel.status.notFound",
                defaultValue: "Chromium not found. Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`."
            )
        }
    }

    /// Chromium exited externally (user ⌘Q'd Chromium, crashed, etc.).
    /// Tear down our CDP client + AX observer and update the view status
    /// so the user sees the state. The panel itself stays open so the
    /// user can close the tab or notice the exit.
    private func handleChromiumExited() {
        guard !isClosed else { return }
        pendingBoundsPush?.cancel()
        pendingBoundsPush = nil
        axObserver?.stop()
        axObserver = nil
        cachedWindowId = nil
        let existingClient = client
        client = nil
        endpoint = nil
        isChromiumExited = true
        statusMessage = String(
            localized: "browserCDP.panel.status.exited",
            defaultValue: "Chromium exited. Click Relaunch to start a new session."
        )
        if let existingClient {
            Task<Void, Never> { await existingClient.close() }
        }
    }

    // MARK: - Navigation

    /// Navigate the panel's Chromium page to `url`. Resolves bare hostnames
    /// (e.g. `example.com`) to `https://example.com` for convenience.
    func navigate(_ raw: String) {
        guard let cdp = client else { return }
        let normalized = Self.normalizeURL(raw)
        currentURL = normalized
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (tid, sid) = try await self.ensurePageSession(cdp: cdp)
                _ = try await cdp.pageNavigate(targetId: tid, sessionId: sid, url: normalized)
            } catch {
                #if DEBUG
                dlog("browserCDP: navigate failed: \(error)")
                #endif
            }
        }
    }

    func reload() {
        guard let cdp = client else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, sid) = try await self.ensurePageSession(cdp: cdp)
                try await cdp.pageReload(sessionId: sid)
            } catch {
                #if DEBUG
                dlog("browserCDP: reload failed: \(error)")
                #endif
            }
        }
    }

    func goBack() {
        guard let cdp = client else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, sid) = try await self.ensurePageSession(cdp: cdp)
                try await cdp.pageGoBack(sessionId: sid)
            } catch {
                #if DEBUG
                dlog("browserCDP: goBack failed: \(error)")
                #endif
            }
        }
    }

    func goForward() {
        guard let cdp = client else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, sid) = try await self.ensurePageSession(cdp: cdp)
                try await cdp.pageGoForward(sessionId: sid)
            } catch {
                #if DEBUG
                dlog("browserCDP: goForward failed: \(error)")
                #endif
            }
        }
    }

    private func ensurePageSession(cdp: ChromiumCDPClient) async throws -> (String, String) {
        if let tid = cachedPageTargetId, let sid = cachedPageSessionId {
            return (tid, sid)
        }
        guard let tid = try await cdp.firstPageTargetId() else {
            throw CDPError.malformedResponse("no page target available")
        }
        let sid = try await cdp.targetAttach(targetId: tid)
        cachedPageTargetId = tid
        cachedPageSessionId = sid
        return (tid, sid)
    }

    private static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ||
           trimmed.hasPrefix("file://") || trimmed.hasPrefix("about:") ||
           trimmed.hasPrefix("chrome://") || trimmed.hasPrefix("data:") {
            return trimmed
        }
        // Hostname shortcut: "example.com" → https, "text with spaces" → google search.
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            return "https://www.google.com/search?q=\(q)"
        }
        return "https://\(trimmed)"
    }

    /// Opt-in capture mode: switch from park (Chromium as its own NSWindow)
    /// to SCStream pixel mirroring + CDP-routed input. No-op on macOS
    /// earlier than 12.3 (SCStream requires Sonoma APIs).
    func setCaptureMode(_ enabled: Bool) {
        guard !isClosed, captureMode != enabled else { return }
        if enabled {
            if #available(macOS 12.3, *) {
                guard let cdp = client, let pid = manager.pid else { return }
                let stream = ChromiumScreenCaptureStream(pid: pid)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await stream.start()
                        self.captureStreamStorage = stream
                        self.inputRouter = ChromiumCDPInputRouter(client: cdp)
                        self.captureMode = true
                        await self.stashChromiumOffScreen()
                    } catch {
                        #if DEBUG
                        dlog("browserCDP: capture start failed: \(error)")
                        #endif
                    }
                }
            }
        } else {
            if #available(macOS 12.3, *) {
                (captureStreamStorage as? ChromiumScreenCaptureStream)?.stop()
            }
            captureStreamStorage = nil
            inputRouter = nil
            captureMode = false
            // Return Chromium to the panel's on-screen rect (park mode).
            if let rect = lastRequestedRect {
                pushBounds(rect)
            }
        }
    }

    /// Try to enter capture mode automatically if Screen Recording
    /// permission is already granted. Called after the CDP client
    /// connects. Silent no-op if permission hasn't been granted —
    /// the user explicitly clicks "Capture" to trigger the prompt.
    private func tryAutoEnableCapture() {
        guard !captureMode, endpoint != nil else { return }
        if #available(macOS 12.3, *) {
            guard CGPreflightScreenCaptureAccess() else { return }
            setCaptureMode(true)
        }
    }

    /// Move Chromium's OS window far off-screen while capture is active.
    /// Keeps the window alive (SCStream requires a rendered window even
    /// if not on any display) but removes it from the user's view so
    /// only the in-panel capture is visible.
    private func stashChromiumOffScreen() async {
        guard let cdp = client else { return }
        let size = lastRequestedRect?.size ?? CGSize(width: 1024, height: 768)
        do {
            let windowId = try await resolveWindowId(with: cdp)
            try await cdp.browserSetWindowBounds(
                windowId: windowId,
                bounds: .init(
                    left: -30000,
                    top: -30000,
                    width: Int(size.width),
                    height: Int(size.height)
                )
            )
        } catch {
            #if DEBUG
            dlog("browserCDP: stash off-screen failed: \(error)")
            #endif
        }
    }

    /// Spawn a fresh Chromium subprocess, reusing this panel's CDP/view
    /// state. Used by the Relaunch button after `handleChromiumExited`.
    func relaunch() {
        guard !isClosed, isChromiumExited else { return }
        isChromiumExited = false
        manager.terminate() // no-op if already torn down; clears userDataDir state
        manager.onProcessExit = { [weak self] in
            self?.handleChromiumExited()
        }
        launch()
    }

    // MARK: - Panel protocol

    func focus() {}
    func unfocus() {}

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingBoundsPush?.cancel()
        pendingBoundsPush = nil
        axObserver?.stop()
        axObserver = nil
        let existingClient = client
        client = nil
        manager.terminate()
        if let existingClient {
            Task<Void, Never> { await existingClient.close() }
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    // MARK: - View integration

    /// Called by the view when its visibility changes (tab switch, window
    /// hide). Minimize Chromium when going offscreen, restore on return.
    func setVisible(_ visible: Bool) {
        guard !isClosed, let cdp = client else { return }
        Task<Void, Never> { [weak self] in
            guard let self else { return }
            let state = visible ? "normal" : "minimized"
            do {
                let windowId = try await self.resolveWindowId(with: cdp)
                _ = try await cdp.send(method: "Browser.setWindowBounds", params: [
                    "windowId": windowId,
                    "bounds": ["windowState": state],
                ])
                // On restore, immediately re-assert the last rect; minimize
                // can shuffle the window off the cmux panel.
                if visible, let rect = await self.readLastRect() {
                    self.pushBounds(rect)
                }
            } catch {
                // Transient; ignore.
            }
        }
    }

    private func readLastRect() async -> CGRect? { lastRequestedRect }

    private func resolveWindowId(with cdp: ChromiumCDPClient) async throws -> Int {
        if let cached = cachedWindowId { return cached }
        guard let targetId = try await cdp.firstPageTargetId() else {
            throw CDPError.malformedResponse("no page target")
        }
        let windowId = try await cdp.browserGetWindowForTarget(targetId: targetId)
        cachedWindowId = windowId
        return windowId
    }

    /// Called by the view when its on-screen rect changes. Top-origin screen
    /// coordinates (CDP convention). The rect is remembered even when the
    /// CDP client is not yet connected; it replays on connect.
    ///
    /// In capture mode we do NOT position Chromium at the panel's on-screen
    /// rect — Chromium is stashed off-screen — but we DO resize it to
    /// match the panel's dimensions so the captured pixels align with
    /// the view 1:1.
    func pushBounds(_ rect: CGRect) {
        guard !isClosed else { return }
        lastRequestedRect = rect
        guard client != nil else { return }
        if captureMode {
            // Match Chromium's window size to the panel (still off-screen)
            // so capture pixels align with the panel 1:1. Debounce so a
            // live resize doesn't spam setWindowBounds.
            pendingBoundsPush?.cancel()
            let block: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    let _: Task<Void, Never> = Task { [weak self] in
                        await self?.stashChromiumOffScreen()
                    }
                }
            }
            let work = DispatchWorkItem(block: block)
            pendingBoundsPush = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.debounceMs),
                execute: work
            )
            return
        }
        pendingBoundsPush?.cancel()
        let block: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { [weak self] in
                    await self?.sendBounds(rect)
                }
            }
        }
        let work = DispatchWorkItem(block: block)
        pendingBoundsPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs), execute: work)
    }

    // MARK: - Private

    private func launch() {
        statusMessage = String(
            localized: "browserCDP.panel.status.launching",
            defaultValue: "Launching Chromium…"
        )
        manager.launch(initialURL: URL(string: "about:blank"), timeout: 15) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let endpoint):
                    self.endpoint = endpoint
                    self.statusMessage = String(
                        format: String(
                            localized: "browserCDP.panel.status.connected",
                            defaultValue: "Connected: %@"
                        ),
                        endpoint.webSocketURL.absoluteString
                    )
                    let transport = CDPWebSocketTransport(url: endpoint.webSocketURL)
                    let cdp = ChromiumCDPClient(transport: transport)
                    self.client = cdp
                    do {
                        try await cdp.connect()
                        if let pending = self.lastRequestedRect {
                            self.pushBounds(pending)
                        }
                        self.installAXObserverIfPossible()
                        self.tryAutoEnableCapture()
                    } catch {
                        self.statusMessage = String(
                            format: String(
                                localized: "browserCDP.panel.status.connectFailed",
                                defaultValue: "CDP connect failed: %@"
                            ),
                            "\(error)"
                        )
                    }
                case .failure(let error):
                    self.statusMessage = String(
                        format: String(
                            localized: "browserCDP.panel.status.launchFailed",
                            defaultValue: "Launch failed: %@"
                        ),
                        "\(error)"
                    )
                }
            }
        }
    }

    private func installAXObserverIfPossible() {
        guard axObserver == nil, let pid = manager.pid else { return }
        let observer = ChromiumAXObserver(pid: pid)
        observer.onWindowMovedOrResized = { [weak self] in
            self?.handleAXWindowEvent()
        }
        guard observer.start() else {
            // Accessibility permission not granted. Reverse sync stays
            // disabled; the forward path (panel → Chromium) still works.
            return
        }
        self.axObserver = observer
    }

    /// User dragged or resized the Chromium window. Wait out the drag
    /// (handler coalesces), then re-assert the panel rect.
    private func handleAXWindowEvent() {
        guard !isClosed, let rect = lastRequestedRect else { return }
        pendingBoundsPush?.cancel()
        let block: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { [weak self] in
                    await self?.sendBounds(rect)
                }
            }
        }
        let work = DispatchWorkItem(block: block)
        pendingBoundsPush = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.axReassertDelayMs),
            execute: work
        )
    }

    private func sendBounds(_ rect: CGRect) async {
        guard let cdp = client, !isClosed else { return }
        do {
            let windowId = try await resolveWindowId(with: cdp)
            try await cdp.browserSetWindowBounds(
                windowId: windowId,
                bounds: .init(
                    left: Int(rect.origin.x),
                    top: Int(rect.origin.y),
                    width: Int(rect.size.width),
                    height: Int(rect.size.height)
                )
            )
        } catch {
            // Transient failures are expected during drag-resize; don't escalate.
        }
    }
}
