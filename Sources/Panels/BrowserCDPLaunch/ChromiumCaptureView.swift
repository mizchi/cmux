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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CaptureLayerView {
        let view = CaptureLayerView()
        sampleBufferStream.onSampleBuffer = { [weak view] buffer in
            view?.updateFromSampleBuffer(buffer)
        }
        return view
    }

    func updateNSView(_ nsView: CaptureLayerView, context: Context) {
        // Nothing to refresh — frames arrive via the stream callback.
    }

    final class Coordinator {}

    final class CaptureLayerView: NSView {
        private let ciContext = CIContext(options: [.cacheIntermediates: false])

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

        /// Called on the main queue.
        func updateFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = ciImage.extent
            guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return }
            layer?.contents = cgImage
        }
    }
}
