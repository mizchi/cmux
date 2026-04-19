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
            layer?.contentsGravity = .resizeAspectFill
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func updateFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = ciImage.extent
            guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return }
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
            // Convert view-local bottom-origin → CDP top-origin, then
            // rescale into the captured content's native pixel space.
            let viewPoint = convert(event.locationInWindow, from: nil)
            let scaleX = lastContentSize.width / max(bounds.width, 1)
            let scaleY = lastContentSize.height / max(bounds.height, 1)
            let flippedY = bounds.height - viewPoint.y
            return CGPoint(x: viewPoint.x * scaleX, y: flippedY * scaleY)
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
