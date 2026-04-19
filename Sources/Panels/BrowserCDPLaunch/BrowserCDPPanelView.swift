import SwiftUI
import AppKit

/// SwiftUI view that hosts a BrowserCDPPanel. Shows a placeholder card
/// (status + CDP URL copy button) and installs a frame observer on the
/// underlying NSView. Every frame change computes the on-screen rect in
/// CDP's top-origin coordinates and asks the panel to push it via CDP.
struct BrowserCDPPanelView: View {
    @ObservedObject var panel: BrowserCDPPanel
    let isFocused: Bool
    let isVisibleInUI: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.07, green: 0.07, blue: 0.09), Color(red: 0.10, green: 0.10, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                ))

            VStack(spacing: 12) {
                Text(String(localized: "browserCDP.panel.bodyText",
                            defaultValue: "Chromium is rendered in its own OS window."))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(panel.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                if let endpoint = panel.endpoint {
                    Button(String(localized: "browserCDP.panel.copyURL",
                                  defaultValue: "Copy CDP URL")) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(endpoint.webSocketURL.absoluteString, forType: .string)
                    }
                    .controlSize(.small)
                }
                if panel.isChromiumExited {
                    Button(String(localized: "browserCDP.panel.relaunch",
                                  defaultValue: "Relaunch Chromium")) {
                        panel.relaunch()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .overlay(
            CDPPanelFrameObserver(
                onScreenRectChange: { [weak panel] rect in
                    panel?.pushBounds(rect)
                },
                onWindowVisibilityChange: { [weak panel] windowVisible in
                    panel?.setVisible(windowVisible)
                }
            )
            .allowsHitTesting(false)
        )
        .onChange(of: isVisibleInUI) { newValue in
            panel.setVisible(newValue)
        }
        .onAppear { panel.setVisible(isVisibleInUI) }
    }
}

/// Uses NSViewRepresentable to attach a bounds observer to the SwiftUI
/// view's backing NSView. Emits the on-screen rect in CDP top-origin coords.
private struct CDPPanelFrameObserver: NSViewRepresentable {
    let onScreenRectChange: (CGRect) -> Void
    let onWindowVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScreenRectChange = onScreenRectChange
        view.onWindowVisibilityChange = onWindowVisibilityChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScreenRectChange = onScreenRectChange
        nsView.onWindowVisibilityChange = onWindowVisibilityChange
    }

    final class ObserverView: NSView {
        var onScreenRectChange: ((CGRect) -> Void)?
        var onWindowVisibilityChange: ((Bool) -> Void)?

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

        private var windowObservers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []

        private func installWindowObservers() {
            let center = NotificationCenter.default
            for token in windowObservers { center.removeObserver(token) }
            windowObservers.removeAll()
            for token in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            workspaceObservers.removeAll()
            guard let window else {
                // View was removed from its window — treat as not visible.
                onWindowVisibilityChange?(false)
                return
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.publishCurrentRect()
                }
                windowObservers.append(token)
            }
            let miniToken = center.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowVisibilityChange?(false)
            }
            windowObservers.append(miniToken)
            let demini = center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowVisibilityChange?(true)
                self?.publishCurrentRect()
            }
            windowObservers.append(demini)
            // Active-space changes (⌃←/→, Mission Control). NSWorkspace
            // fires this on every Space transition; we inspect whether our
            // window is on the new active Space and route visibility.
            let spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                let visible = window.isOnActiveSpace && !window.isMiniaturized && window.isVisible
                self.onWindowVisibilityChange?(visible)
                if visible { self.publishCurrentRect() }
            }
            workspaceObservers.append(spaceToken)
            // Propagate current visibility on install (miniaturized state is
            // sticky across window-assignment transitions).
            onWindowVisibilityChange?(
                !window.isMiniaturized && window.isVisible && window.isOnActiveSpace
            )
        }

        private func publishCurrentRect() {
            guard let window, let screen = window.screen ?? NSScreen.screens.first else { return }
            let rectInWindow = convert(bounds, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            // Flip to CDP top-origin coords. Use the primary screen height
            // like CDP expects.
            let primary = NSScreen.screens.first ?? screen
            let primaryHeight = primary.frame.size.height
            let topY = primaryHeight - (rectOnScreen.origin.y + rectOnScreen.size.height)
            let cdpRect = CGRect(
                x: rectOnScreen.origin.x,
                y: topY,
                width: rectOnScreen.size.width,
                height: rectOnScreen.size.height
            )
            onScreenRectChange?(cdpRect)
        }

        deinit {
            let center = NotificationCenter.default
            for token in windowObservers { center.removeObserver(token) }
            for token in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
        }
    }
}
