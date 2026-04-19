import Foundation
import Combine
import AppKit
#if DEBUG
import Bonsplit
#endif

/// Panel that hosts a headless Chromium process driven entirely through
/// CDP. Rendering uses `Page.startScreencast` (no native Chromium
/// window, no Screen Recording permission); input uses
/// `Input.dispatchMouseEvent` / `dispatchKeyEvent` through
/// `ChromiumCDPInputRouter`. Viewport size tracks the panel's NSView
/// via `Emulation.setDeviceMetricsOverride`.
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

    /// CDP endpoint once the subprocess is up. Nil while launching / exited.
    @Published private(set) var endpoint: ChromiumDevToolsEndpoint?
    @Published private(set) var statusMessage: String = String(
        localized: "browserCDP.panel.status.launching",
        defaultValue: "Launching Chromium…"
    )
    /// Mirrors the most recent `navigate(_:)` target so the panel's
    /// address bar stays in sync with programmatic navigation.
    @Published var currentURL: String = "about:blank"
    /// Surfaces a "Relaunch" action in the view when Chromium exits.
    @Published private(set) var isChromiumExited: Bool = false

    private let manager: ChromiumLaunchManager
    private var client: ChromiumCDPClient?
    private var pageTargetId: String?
    private var pageSessionId: String?
    private var pendingViewportPush: DispatchWorkItem?
    private var isClosed = false
    /// Remembered even while the CDP client is still connecting, so the
    /// first render already matches the panel's on-screen size.
    private var lastViewportSize: CGSize?

    /// Active screencast session once CDP is up. Exposed so the view's
    /// subscriber can attach to its `onFrame` callback directly.
    private(set) var screencast: ChromiumScreencastSession?
    /// Input router bound to the attached page session. Used by the view
    /// to dispatch mouse / key events.
    private(set) var inputRouter: ChromiumCDPInputRouter?

    private static let resizeDebounceMs: Int = 16

    init() {
        self.id = UUID()
        let locator = ChromiumBinaryLocator()
        do {
            let binary = try locator.locate()
            self.manager = ChromiumLaunchManager(binary: binary)
            manager.onProcessExit = { [weak self] in self?.handleChromiumExited() }
            launch()
        } catch {
            self.manager = ChromiumLaunchManager(
                binary: ChromiumBinary(path: "/dev/null", source: .envOverride)
            )
            self.statusMessage = String(
                localized: "browserCDP.panel.status.notFound",
                defaultValue: "Chromium not found. Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`."
            )
        }
    }

    // MARK: - Panel protocol

    func focus() {}
    func unfocus() {}

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingViewportPush?.cancel()
        pendingViewportPush = nil
        let session = screencast
        screencast = nil
        let cdp = client
        client = nil
        manager.terminate()
        Task<Void, Never> {
            await session?.stop()
            await cdp?.close()
        }
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    // MARK: - Navigation

    /// Navigate the page to `url`. Bare hostnames become `https://`,
    /// free text becomes a Google search.
    func navigate(_ raw: String) {
        guard let cdp = client else { return }
        let normalized = Self.normalizeURL(raw)
        currentURL = normalized
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (tid, sid) = try await self.ensurePageSession(cdp: cdp)
                _ = try await cdp.pageNavigate(targetId: tid, sessionId: sid, url: normalized)
            } catch { self.logNavError("navigate", error) }
        }
    }

    func reload()     { runOnSession { cdp, sid in try await cdp.pageReload(sessionId: sid) } }
    func goBack()     { runOnSession { cdp, sid in try await cdp.pageGoBack(sessionId: sid) } }
    func goForward()  { runOnSession { cdp, sid in try await cdp.pageGoForward(sessionId: sid) } }

    private func runOnSession(_ body: @escaping (ChromiumCDPClient, String) async throws -> Void) {
        guard let cdp = client else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, sid) = try await self.ensurePageSession(cdp: cdp)
                try await body(cdp, sid)
            } catch { self.logNavError("session op", error) }
        }
    }

    // MARK: - Relaunch after external exit

    func relaunch() {
        guard !isClosed, isChromiumExited else { return }
        isChromiumExited = false
        manager.terminate()
        manager.onProcessExit = { [weak self] in self?.handleChromiumExited() }
        launch()
    }

    private func handleChromiumExited() {
        guard !isClosed else { return }
        pendingViewportPush?.cancel()
        pendingViewportPush = nil
        pageTargetId = nil
        pageSessionId = nil
        let session = screencast
        screencast = nil
        let cdp = client
        client = nil
        endpoint = nil
        inputRouter = nil
        isChromiumExited = true
        statusMessage = String(
            localized: "browserCDP.panel.status.exited",
            defaultValue: "Chromium exited. Click Relaunch to start a new session."
        )
        Task<Void, Never> {
            await session?.stop()
            await cdp?.close()
        }
    }

    // MARK: - View integration

    /// Called by the panel view each time its on-screen size changes.
    /// Drives `Emulation.setDeviceMetricsOverride` + screencast resize
    /// after a 16 ms debounce so live drags don't spam CDP.
    func pushBounds(_ rect: CGRect) {
        guard !isClosed else { return }
        lastViewportSize = rect.size
        guard client != nil else { return }
        pendingViewportPush?.cancel()
        let block: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { [weak self] in
                    await self?.applyViewportSize(rect.size)
                }
            }
        }
        let work = DispatchWorkItem(block: block)
        pendingViewportPush = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.resizeDebounceMs),
            execute: work
        )
    }

    /// Legacy no-op kept for the panel view's setVisible / setCaptureMode
    /// bindings that are still on the call graph. Headless screencast
    /// doesn't need visibility transitions — the rendering is invisible
    /// until we decode a frame into the CALayer.
    func setVisible(_ visible: Bool) { _ = visible }
    func setCaptureMode(_ enabled: Bool) { _ = enabled }

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
                case .success(let ep):
                    self.endpoint = ep
                    self.statusMessage = String(
                        format: String(
                            localized: "browserCDP.panel.status.connected",
                            defaultValue: "Connected: %@"
                        ),
                        ep.webSocketURL.absoluteString
                    )
                    let transport = CDPWebSocketTransport(url: ep.webSocketURL)
                    let cdp = ChromiumCDPClient(transport: transport)
                    self.client = cdp
                    do {
                        try await cdp.connect()
                        try await self.startScreencast(cdp: cdp)
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

    private func startScreencast(cdp: ChromiumCDPClient) async throws {
        let size = lastViewportSize ?? CGSize(width: 1280, height: 800)
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let (_, sid) = try await ensurePageSession(cdp: cdp)
        inputRouter = ChromiumCDPInputRouter(client: cdp, sessionId: sid)
        try await cdp.emulationSetDeviceMetricsOverride(
            sessionId: sid,
            width: Int(size.width),
            height: Int(size.height),
            deviceScaleFactor: Double(scale)
        )
        let session = ChromiumScreencastSession(client: cdp)
        screencast = session
        try await session.start(
            pageSessionId: sid,
            maxWidth: Int(size.width) * scale,
            maxHeight: Int(size.height) * scale
        )
    }

    private func applyViewportSize(_ size: CGSize) async {
        guard let cdp = client, let sid = pageSessionId else { return }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let w = max(Int(size.width), 200)
        let h = max(Int(size.height), 150)
        do {
            try await cdp.emulationSetDeviceMetricsOverride(
                sessionId: sid,
                width: w,
                height: h,
                deviceScaleFactor: scale
            )
            try await screencast?.resize(
                maxWidth: w * Int(scale),
                maxHeight: h * Int(scale)
            )
        } catch { logNavError("viewport resize", error) }
    }

    private func ensurePageSession(cdp: ChromiumCDPClient) async throws -> (String, String) {
        if let tid = pageTargetId, let sid = pageSessionId { return (tid, sid) }
        guard let tid = try await cdp.firstPageTargetId() else {
            throw CDPError.malformedResponse("no page target available")
        }
        let sid = try await cdp.targetAttach(targetId: tid)
        pageTargetId = tid
        pageSessionId = sid
        return (tid, sid)
    }

    private static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }
        let schemePrefixes = ["http://", "https://", "file://", "about:", "chrome://", "data:"]
        if schemePrefixes.contains(where: trimmed.hasPrefix) { return trimmed }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            return "https://www.google.com/search?q=\(q)"
        }
        return "https://\(trimmed)"
    }

    private func logNavError(_ context: String, _ error: Error) {
        #if DEBUG
        dlog("browserCDP: \(context) failed: \(error)")
        #endif
    }
}
