import Foundation
import AppKit
import CoreGraphics

/// Drives Chromium's `Page.startScreencast` stream and decodes each
/// base64-JPEG frame into a CGImage. The panel view subscribes to
/// `onFrame` to render each image and call `ackFrame(_:)` back so
/// Chromium unblocks the next frame.
@MainActor
final class ChromiumScreencastSession {
    var onFrame: ((CGImage) -> Void)?

    private let client: ChromiumCDPClient
    private var pageSessionId: String?
    private var isRunning = false

    init(client: ChromiumCDPClient) {
        self.client = client
    }

    /// Start screencast against the given page session. Width/height are
    /// in device pixels — typically panel points × backing scale factor.
    func start(pageSessionId: String, maxWidth: Int, maxHeight: Int) async throws {
        guard !isRunning else { return }
        self.pageSessionId = pageSessionId

        // Subscribe to Page events (screencastFrame) via the client's
        // shared event handler.
        await client.setEventHandler { [weak self] method, params, sessionId in
            guard let self else { return }
            guard method == "Page.screencastFrame" else { return }
            // Event might come in either on the page session or flat —
            // accept both and trust the session filter below.
            _ = sessionId
            Task { @MainActor in
                self.handleFrame(params: params)
            }
        }

        try await client.pageEnable(sessionId: pageSessionId)
        try await client.pageStartScreencast(
            sessionId: pageSessionId,
            format: "jpeg",
            quality: 80,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
        isRunning = true
    }

    func stop() async {
        guard isRunning, let sid = pageSessionId else { return }
        isRunning = false
        try? await client.pageStopScreencast(sessionId: sid)
        await client.setEventHandler(nil)
    }

    /// Adjust the screencast dimensions mid-stream. Implemented as
    /// stop+start since CDP has no in-place resize.
    func resize(maxWidth: Int, maxHeight: Int) async throws {
        guard let sid = pageSessionId else { return }
        if isRunning {
            try? await client.pageStopScreencast(sessionId: sid)
        }
        try await client.pageStartScreencast(
            sessionId: sid,
            format: "jpeg",
            quality: 80,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
        isRunning = true
    }

    // MARK: - Frame pipeline

    private func handleFrame(params: [String: Any]) {
        guard let dataB64 = params["data"] as? String,
              let jpeg = Data(base64Encoded: dataB64),
              let ns = NSImage(data: jpeg),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            ackIfNeeded(params: params)
            return
        }
        onFrame?(cg)
        ackIfNeeded(params: params)
    }

    private func ackIfNeeded(params: [String: Any]) {
        guard let sid = pageSessionId else { return }
        // CDP uses `sessionId` inside the screencastFrame params (an
        // integer, unrelated to the target sessionId). Ack echoes it.
        guard let frameSid = params["sessionId"] as? Int else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.client.pageScreencastFrameAck(sessionId: sid, frameSessionId: frameSid)
        }
    }
}
