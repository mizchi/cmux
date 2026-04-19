import Foundation
import ApplicationServices
import AppKit

/// Watches the Chromium application's windows via the macOS Accessibility
/// API and reports user-initiated moves / resizes so the panel can
/// re-assert its target rect.
///
/// Phase 2b: the forward sync (cmux panel rect → Chromium) is driven by
/// `Browser.setWindowBounds` over CDP. The reverse sync (Chromium window
/// dragged by the user → snap back) requires Accessibility permission.
/// If permission is denied we silently stay idle; the user retains
/// manual control of the Chromium window.
///
/// The observer intentionally delivers events on the main queue via
/// `CFRunLoopAddSource(CFRunLoopGetMain(), ...)` so callers can touch
/// AppKit state directly.
@MainActor
final class ChromiumAXObserver {
    /// Called on every window move / resize on the observed app.
    var onWindowMovedOrResized: (() -> Void)?

    private let pid: pid_t
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var isStarted = false

    init(pid: pid_t) {
        self.pid = pid
    }

    /// Start observing. Returns false if Accessibility permission is not
    /// granted — caller should surface that to the user and decide whether
    /// to prompt via `AXIsProcessTrustedWithOptions`.
    @discardableResult
    func start() -> Bool {
        guard !isStarted else { return true }
        guard AXIsProcessTrusted() else { return false }

        let app = AXUIElementCreateApplication(pid)
        var rawObserver: AXObserver?
        let createStatus = AXObserverCreate(pid, ChromiumAXObserver.callback, &rawObserver)
        guard createStatus == .success, let rawObserver else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [CFString] = [
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
        ]
        for name in notifications {
            let status = AXObserverAddNotification(rawObserver, app, name, refcon)
            // -25204 (kAXErrorNotificationUnsupported) is possible for
            // apps that don't expose a given notification — ignore.
            _ = status
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(rawObserver),
            .defaultMode
        )

        self.appElement = app
        self.observer = rawObserver
        self.isStarted = true
        return true
    }

    func stop() {
        guard isStarted, let observer else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
        self.appElement = nil
        self.isStarted = false
    }

    deinit {
        // stop() needs @MainActor; release Core Foundation refs by letting
        // the optionals drop — AXObserver is ref-counted.
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<ChromiumAXObserver>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async {
            observer.onWindowMovedOrResized?()
        }
    }
}

/// Checks whether the current process has Accessibility permission.
/// Pass `prompt: true` exactly once to open the system permission dialog;
/// repeated prompts are suppressed by the OS but the prompt can be
/// visually jarring so prefer a single deliberate call.
func chromiumAXPermissionGranted(prompt: Bool = false) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
    let options = [promptKey: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}
