import SwiftUI
import AppKit

/// Panel UI for BrowserCDPPanel. Top: address bar + back/forward/reload.
/// Body: a `ChromiumScreencastView` that renders headless Chromium's
/// screencast frames and forwards NSEvents through `panel.inputRouter`.
struct BrowserCDPPanelView: View {
    @ObservedObject var panel: BrowserCDPPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    @State private var addressFieldText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            ChromiumScreencastView(
                inputRouter: panel.inputRouter,
                attachView: { [weak panel] nsView in
                    panel?.screencast?.onFrame = { [weak nsView] cg in
                        nsView?.setFrame(cg)
                    }
                }
            )
        }
        .overlay(
            CDPPanelFrameObserver(onScreenRectChange: { [weak panel] rect in
                panel?.pushBounds(rect)
            })
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder private var addressBar: some View {
        HStack(spacing: 6) {
            Button(action: { panel.goBack() })    { Image(systemName: "chevron.backward") }
                .buttonStyle(.borderless)
                .disabled(panel.endpoint == nil)

            Button(action: { panel.goForward() }) { Image(systemName: "chevron.forward") }
                .buttonStyle(.borderless)
                .disabled(panel.endpoint == nil)

            Button(action: { panel.reload() })    { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(panel.endpoint == nil)

            TextField("example.com / https://… / search…", text: $addressFieldText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let s = addressFieldText.trimmingCharacters(in: .whitespaces)
                    guard !s.isEmpty else { return }
                    panel.navigate(s)
                }

            if panel.isChromiumExited {
                Button(String(
                    localized: "browserCDP.panel.relaunch",
                    defaultValue: "Relaunch"
                )) {
                    panel.relaunch()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: panel.currentURL) { newValue in
            if addressFieldText != newValue { addressFieldText = newValue }
        }
        .onAppear {
            if addressFieldText.isEmpty { addressFieldText = panel.currentURL }
        }
    }
}

/// NSView observer that reports the panel view's on-screen rect. The
/// panel uses it to drive `Emulation.setDeviceMetricsOverride` so the
/// rendered viewport always matches the container size.
private struct CDPPanelFrameObserver: NSViewRepresentable {
    let onScreenRectChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onScreenRectChange = onScreenRectChange
        return v
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScreenRectChange = onScreenRectChange
    }

    final class ObserverView: NSView {
        var onScreenRectChange: ((CGRect) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            postsFrameChangedNotifications = true
            postsBoundsChangedNotifications = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            postsFrameChangedNotifications = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installWindowObservers()
            publishCurrentRect()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            publishCurrentRect()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            publishCurrentRect()
        }

        deinit {
            let center = NotificationCenter.default
            for token in windowObservers { center.removeObserver(token) }
        }

        private func installWindowObservers() {
            let center = NotificationCenter.default
            for token in windowObservers { center.removeObserver(token) }
            windowObservers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification,
                         NSWindow.didEndLiveResizeNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.publishCurrentRect()
                }
                windowObservers.append(token)
            }
        }

        private func publishCurrentRect() {
            // The panel only cares about *size* for Emulation.setDeviceMetricsOverride;
            // position is irrelevant in headless mode. We still publish a full rect
            // so the call site can switch to positional data without another change.
            onScreenRectChange?(bounds)
        }
    }
}
