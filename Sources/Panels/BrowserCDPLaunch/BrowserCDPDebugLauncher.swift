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

    private static func installTerminateObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    if let c = client { await c.close() }
                    client = nil
                    manager?.terminate()
                    manager = nil
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
