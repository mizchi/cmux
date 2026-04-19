import SwiftUI
import AppKit
import CoreImage
import CoreMedia
import CoreVideo

/// Lightweight preview layer for the SCStream fallback mode. Draws the
/// latest CMSampleBuffer as a CIImage into an NSView layer. Not yet
/// hooked up to BrowserCDPPanel — reserved for phase 3b when the panel
/// gains an explicit capture/park toggle.
///
/// Rendering is CPU-side (CIImage → CGImage) for simplicity; a future
/// pass can move to IOSurface + MTKView for zero-copy. Input routing is
/// intentionally NOT part of this view — the panel's park path is still
/// the primary interaction surface in phase 3b.
@available(macOS 12.3, *)
struct ChromiumCaptureView: NSViewRepresentable {
    let sampleBufferStream: ChromiumScreenCaptureStream
    let inputRouter: ChromiumCDPInputRouter?
    /// Content size in CDP pixel coords. Set from the most recent sample
    /// buffer so click coordinates can be rescaled from NSView → CDP.
    @Binding var contentSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CaptureLayerView {
        let view = CaptureLayerView()
        view.inputRouter = inputRouter
        view.contentSizeBinding = $contentSize
        sampleBufferStream.onSampleBuffer = { [weak view] buffer in
            view?.updateFromSampleBuffer(buffer)
        }
        return view
    }

    func updateNSView(_ nsView: CaptureLayerView, context: Context) {
        nsView.inputRouter = inputRouter
        nsView.contentSizeBinding = $contentSize
    }

    final class Coordinator {}

    final class CaptureLayerView: NSView {
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        var inputRouter: ChromiumCDPInputRouter?
        var contentSizeBinding: Binding<CGSize>?
        private var lastContentSize: CGSize = .zero

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

        private func commonInit() {
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            if let screen = window?.screen ?? NSScreen.main {
                layer?.contentsScale = screen.backingScaleFactor
            }
        }

        /// Ensure AppKit doesn't replace our backing layer with one that
        /// lacks our contentsGravity setting during view-hierarchy churn.
        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            layer.masksToBounds = true
            if let screen = NSScreen.main {
                layer.contentsScale = screen.backingScaleFactor
            }
            return layer
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let screen = window?.screen {
                layer?.contentsScale = screen.backingScaleFactor
            }
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func updateFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = ciImage.extent
            guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return }
            // Re-assert gravity + contentsScale on every frame; AppKit can
            // reset these during layout/tab-switch churn, and the right
            // scale depends on the current screen (which the view may not
            // have known at construction time).
            let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            layer?.contentsScale = scale
            layer?.contentsGravity = .resizeAspect
            layer?.contents = cgImage
            let newSize = CGSize(width: extent.width, height: extent.height)
            if newSize != lastContentSize {
                lastContentSize = newSize
                DispatchQueue.main.async { [weak self] in
                    self?.contentSizeBinding?.wrappedValue = newSize
                }
            }
        }

        // MARK: - Input forwarding

        private func contentPoint(for event: NSEvent) -> CGPoint {
            // Map view-local NSEvent point → Chromium CSS-pixel viewport coord,
            // accounting for (1) backing-scale between capture pixels and CSS
            // pixels, (2) `.resizeAspect` letterbox offsets inside the view.
            let viewPoint = convert(event.locationInWindow, from: nil)
            let backing = window?.screen?.backingScaleFactor ?? 2
            guard lastContentSize.width > 0, lastContentSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else {
                return .zero
            }
            // Captured image is in device pixels; convert to CSS points.
            let imagePointWidth = lastContentSize.width / backing
            let imagePointHeight = lastContentSize.height / backing
            // Aspect-fit: the image occupies a centered rectangle that fills
            // one axis completely and is letterboxed on the other.
            let scale = min(bounds.width / imagePointWidth,
                            bounds.height / imagePointHeight)
            let displayedW = imagePointWidth * scale
            let displayedH = imagePointHeight * scale
            let offsetX = (bounds.width - displayedW) / 2
            let offsetY = (bounds.height - displayedH) / 2
            let localX = (viewPoint.x - offsetX) / scale
            // NSView uses bottom-origin; CDP uses top-origin.
            let flippedY = bounds.height - viewPoint.y
            let localY = (flippedY - offsetY) / scale
            return CGPoint(x: localX, y: localY)
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

        private func dispatchMouse(_ event: NSEvent) {
            guard let router = inputRouter else { return }
            let pt = contentPoint(for: event)
            Task { @MainActor in await router.dispatchMouse(event: event, atWindowPoint: pt) }
        }
    }
}
