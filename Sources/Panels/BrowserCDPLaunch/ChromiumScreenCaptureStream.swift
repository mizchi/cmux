import Foundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Single-window screen capture for a Chromium subprocess. Phase 3b fallback
/// for the "park and follow" strategy: when the Chromium window is occluded
/// or on a different Space, we can still mirror pixels into the cmux panel
/// via ScreenCaptureKit. Input routing (mouse/key → CDP Input.dispatch*)
/// is a separate unit; this class only produces frames.
///
/// Requires the Screen Recording TCC entitlement. On macOS 15+ the system
/// re-prompts weekly. Caller should gate on `SCShareableContent` success
/// and surface a clear permission banner on failure.
@available(macOS 12.3, *)
@MainActor
final class ChromiumScreenCaptureStream: NSObject, SCStreamDelegate, SCStreamOutput {
    enum StreamError: Error, CustomStringConvertible {
        case permissionDenied
        case windowNotFound(pid: pid_t)
        case streamFailed(String)

        var description: String {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission not granted"
            case .windowNotFound(let pid):
                return "No capturable window for Chromium PID \(pid)"
            case .streamFailed(let msg):
                return "SCStream failed: \(msg)"
            }
        }
    }

    /// Delivered on the main queue. Consumer renders the buffer into an
    /// MTKView / NSImageView via CIImage or IOSurface.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((StreamError) -> Void)?

    private let pid: pid_t
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "cmux.chromium.sccapture", qos: .userInteractive)

    init(pid: pid_t) {
        self.pid = pid
        super.init()
    }

    /// Look up the main Chromium window for `pid` and begin streaming it.
    /// Fails if permission is missing or the process has no on-screen
    /// window yet (Chromium needs ~1s after launch to get there).
    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw StreamError.permissionDenied
        }

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && ($0.title != nil)
        }) else {
            throw StreamError.windowNotFound(pid: pid)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * (NSScreen.main?.backingScaleFactor ?? 2))
        config.height = Int(window.frame.height * (NSScreen.main?.backingScaleFactor ?? 2))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // Clip to the window's non-title content if we want to hide the
        // Chromium title bar later; leave visible for phase 3b so the
        // user can still see the full native UI.

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            throw StreamError.streamFailed("\(error)")
        }

        do {
            try await stream.startCapture()
        } catch {
            throw StreamError.streamFailed("\(error)")
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onSampleBuffer?(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(.streamFailed("\(error)"))
        }
    }
}
