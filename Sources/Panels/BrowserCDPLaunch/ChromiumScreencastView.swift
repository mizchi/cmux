import SwiftUI
import AppKit

/// SwiftUI host for the headless Chromium screencast. Renders incoming
/// CGImage frames into a CALayer and forwards mouse / key events to the
/// panel's CDP input router.
struct ChromiumScreencastView: NSViewRepresentable {
    let inputRouter: ChromiumCDPInputRouter?
    /// Receives the NSView so the panel can push new frames into it.
    let attachView: (ScreencastNSView) -> Void

    func makeNSView(context: Context) -> ScreencastNSView {
        let v = ScreencastNSView()
        v.inputRouter = inputRouter
        attachView(v)
        return v
    }

    func updateNSView(_ nsView: ScreencastNSView, context: Context) {
        nsView.inputRouter = inputRouter
    }
}

/// AppKit view that holds a CALayer backing and renders each CGImage
/// pushed to it. Forwards NSEvent input through the attached router.
final class ScreencastNSView: NSView {
    var inputRouter: ChromiumCDPInputRouter?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        commonInit()
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.black.cgColor
        if let screen = NSScreen.main {
            layer.contentsScale = screen.backingScaleFactor
        }
        return layer
    }

    private func commonInit() {
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        if let screen = window?.screen ?? NSScreen.main {
            layer?.contentsScale = screen.backingScaleFactor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screen = window?.screen {
            layer?.contentsScale = screen.backingScaleFactor
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Pushed from BrowserCDPPanel each time a new screencast frame
    /// arrives. Called on the main thread.
    func setFrame(_ cgImage: CGImage) {
        layer?.contents = cgImage
    }

    // MARK: - Input forwarding

    /// Convert view-local NSEvent point → CDP CSS-pixel coord. With
    /// headless + Emulation.setDeviceMetricsOverride matching the panel
    /// size in CSS pixels, the mapping is just a y-flip (AppKit bottom-
    /// origin → CDP top-origin) with no scaling.
    private func contentPoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func dispatchMouse(_ event: NSEvent) {
        guard let router = inputRouter else { return }
        let pt = contentPoint(for: event)
        Task { @MainActor in await router.dispatchMouse(event: event, atWindowPoint: pt) }
    }

    override func mouseDown(with event: NSEvent)        { dispatchMouse(event) }
    override func mouseUp(with event: NSEvent)          { dispatchMouse(event) }
    override func mouseMoved(with event: NSEvent)       { dispatchMouse(event) }
    override func mouseDragged(with event: NSEvent)     { dispatchMouse(event) }
    override func rightMouseDown(with event: NSEvent)   { dispatchMouse(event) }
    override func rightMouseUp(with event: NSEvent)     { dispatchMouse(event) }
    override func rightMouseDragged(with event: NSEvent){ dispatchMouse(event) }
    override func otherMouseDown(with event: NSEvent)   { dispatchMouse(event) }
    override func otherMouseUp(with event: NSEvent)     { dispatchMouse(event) }
    override func otherMouseDragged(with event: NSEvent){ dispatchMouse(event) }
    override func scrollWheel(with event: NSEvent)      { dispatchMouse(event) }

    override func keyDown(with event: NSEvent) {
        guard let router = inputRouter else { super.keyDown(with: event); return }
        Task { @MainActor in await router.dispatchKey(event: event, type: .keyDown) }
    }

    override func keyUp(with event: NSEvent) {
        guard let router = inputRouter else { super.keyUp(with: event); return }
        Task { @MainActor in await router.dispatchKey(event: event, type: .keyUp) }
    }
}
