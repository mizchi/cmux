import Foundation
import Combine
import AppKit

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

    @Published private(set) var displayTitle: String = "Chromium"
    var displayIcon: String? { "globe" }
    @Published private(set) var focusFlashToken: Int = 0

    /// Current CDP endpoint once the subprocess is up. Nil while launching or on failure.
    @Published private(set) var endpoint: ChromiumDevToolsEndpoint?
    @Published private(set) var statusMessage: String = "Launching Chromium…"

    private let manager: ChromiumLaunchManager
    private var client: ChromiumCDPClient?
    private var axObserver: ChromiumAXObserver?
    private var cachedWindowId: Int?
    private var pendingBoundsPush: DispatchWorkItem?
    private var isClosed = false
    /// Remembered even while the CDP client is still connecting, so we can
    /// replay the first known rect as soon as the client comes up.
    private var lastRequestedRect: CGRect?
    /// Tracks whether Chromium has exited externally; surfaces as a Relaunch
    /// button in the view.
    @Published private(set) var isChromiumExited: Bool = false
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
            self.statusMessage = "Chromium not found. Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`."
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
        statusMessage = "Chromium exited. Click Relaunch to start a new session."
        if let existingClient {
            Task<Void, Never> { await existingClient.close() }
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

    /// Called by the view when its on-screen rect changes. Top-origin screen
    /// coordinates (CDP convention). The rect is remembered even when the
    /// CDP client is not yet connected; it replays on connect.
    func pushBounds(_ rect: CGRect) {
        guard !isClosed else { return }
        lastRequestedRect = rect
        guard client != nil else { return }
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
        statusMessage = "Launching Chromium…"
        manager.launch(initialURL: URL(string: "about:blank"), timeout: 15) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let endpoint):
                    self.endpoint = endpoint
                    self.statusMessage = "Connected: \(endpoint.webSocketURL.absoluteString)"
                    let transport = CDPWebSocketTransport(url: endpoint.webSocketURL)
                    let cdp = ChromiumCDPClient(transport: transport)
                    self.client = cdp
                    do {
                        try await cdp.connect()
                        if let pending = self.lastRequestedRect {
                            self.pushBounds(pending)
                        }
                        self.installAXObserverIfPossible()
                    } catch {
                        self.statusMessage = "CDP connect failed: \(error)"
                    }
                case .failure(let error):
                    self.statusMessage = "Launch failed: \(error)"
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
            let windowId: Int
            if let cached = cachedWindowId {
                windowId = cached
            } else {
                guard let targetId = try await cdp.firstPageTargetId() else { return }
                windowId = try await cdp.browserGetWindowForTarget(targetId: targetId)
                cachedWindowId = windowId
            }
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
