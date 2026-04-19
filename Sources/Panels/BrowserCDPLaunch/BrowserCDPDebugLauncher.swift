#if DEBUG
import AppKit
import Bonsplit

@MainActor
enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?
    private static var client: ChromiumCDPClient?
    private static var observerInstalled = false
    private static var autoFollow = false
    private static var followedWindow: NSWindow?
    private static var followObservers: [NSObjectProtocol] = []
    private static var pendingBoundsPush: DispatchWorkItem?
    private static var cachedWindowId: Int?
    private static let followDebounceMs: Int = 16

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

        autoFollow = false
        removeFollowObservers()
        followedWindow = nil
        cachedWindowId = nil
        manager?.terminate()
        if let existing = client { await existing.close() }
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

    static func toggleAutoFollow() {
        autoFollow.toggle()
        if autoFollow {
            guard client != nil else {
                autoFollow = false
                presentAlert(title: "No Chromium running",
                             body: "Use “Launch Chromium (CDP)…” first.")
                return
            }
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
                autoFollow = false
                presentAlert(title: "No cmux window",
                             body: "Bring a cmux window to the foreground first.")
                return
            }
            followedWindow = window
            installFollowObservers(for: window)
            dlog("browserCDP: auto-follow ON, window=\(ObjectIdentifier(window))")
            scheduleBoundsPush()
        } else {
            removeFollowObservers()
            followedWindow = nil
            cachedWindowId = nil
            dlog("browserCDP: auto-follow OFF")
        }
    }

    private static func installFollowObservers(for window: NSWindow) {
        removeFollowObservers()
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleBoundsPush() }
            }
            followObservers.append(token)
        }
    }

    private static func removeFollowObservers() {
        let center = NotificationCenter.default
        for token in followObservers { center.removeObserver(token) }
        followObservers.removeAll()
        pendingBoundsPush?.cancel()
        pendingBoundsPush = nil
    }

    private static func scheduleBoundsPush() {
        pendingBoundsPush?.cancel()
        let block: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { await pushBoundsNow() }
            }
        }
        let work = DispatchWorkItem(block: block)
        pendingBoundsPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(followDebounceMs), execute: work)
    }

    private static func pushBoundsNow() async {
        guard autoFollow, let cdp = client else { return }
        guard let screenRect = cmuxMainWindowScreenRect() else { return }
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
                    left: Int(screenRect.origin.x),
                    top: Int(screenRect.origin.y),
                    width: Int(screenRect.size.width),
                    height: Int(screenRect.size.height)
                )
            )
        } catch {
            dlog("browserCDP: auto-follow setWindowBounds failed: \(error)")
        }
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
                autoFollow = false
                removeFollowObservers()
                followedWindow = nil
                cachedWindowId = nil
                let existingClient = client
                client = nil
                manager?.terminate()
                manager = nil
                if let existingClient {
                    Task<Void, Never> { await existingClient.close() }
                }
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
