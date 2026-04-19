#if DEBUG
import AppKit
import Bonsplit

enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?

    static func launchAndReportURL() async {
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

    @MainActor
    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
