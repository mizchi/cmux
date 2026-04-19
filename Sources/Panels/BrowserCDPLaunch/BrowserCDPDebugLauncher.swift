#if DEBUG
import AppKit
import Bonsplit

enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?
    private static var observerInstalled = false

    static func launchAndReportURL() async {
        installTerminateObserverIfNeeded()
        let locator = ChromiumBinaryLocator()
        let binary: ChromiumBinary
        do {
            binary = try locator.locate()
        } catch {
            dlog("browserCDP: locate failed: \(error)")
            await presentAlert(title: "Chromium not found",
                               body: "Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`.")
            return
        }
        dlog("browserCDP: using \(binary.source.rawValue) at \(binary.path)")

        manager?.terminate()
        let mgr = ChromiumLaunchManager(binary: binary)
        manager = mgr
        mgr.launch(initialURL: URL(string: "about:blank"), timeout: 15) { result in
            switch result {
            case .success(let endpoint):
                let url = endpoint.webSocketURL.absoluteString
                dlog("browserCDP: \(url)")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                Task { await presentAlert(title: "Chromium launched",
                                          body: "CDP URL copied to clipboard:\n\(url)") }
            case .failure(let error):
                dlog("browserCDP: launch failed: \(error)")
                Task { await presentAlert(title: "Chromium launch failed",
                                          body: "\(error)") }
            }
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
            manager?.terminate()
            manager = nil
        }
    }

    @MainActor
    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
