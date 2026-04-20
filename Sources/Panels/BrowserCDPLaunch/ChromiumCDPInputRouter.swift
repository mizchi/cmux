import Foundation
import AppKit

/// Translates cmux `NSEvent`s into CDP `Input.dispatch*` messages so
/// the screencast view can be interactive while Chromium runs
/// headlessly. Phase 3c scope: mouse press / release / move / wheel
/// + basic key down / up. IME composition and drag-and-drop are
/// deferred.
@MainActor
final class ChromiumCDPInputRouter {
    private let client: ChromiumCDPClient
    /// Page-session the `Input.dispatch*` calls are routed through.
    /// Required for headless mode where browser-level input has no
    /// default target.
    var sessionId: String?

    init(client: ChromiumCDPClient, sessionId: String? = nil) {
        self.client = client
        self.sessionId = sessionId
    }

    enum KeyType: String { case keyDown, keyUp }

    // MARK: - Dispatch

    /// Send a mouse event. `location` is the cursor position within
    /// the rendered viewport, in top-origin CSS pixels (CDP convention).
    func dispatchMouse(event: NSEvent, atWindowPoint location: CGPoint) async {
        guard let type = Self.cdpMouseType(for: event.type) else { return }
        var params: [String: Any] = [
            "type": type,
            "x": Int(location.x),
            "y": Int(location.y),
            "button": Self.cdpButton(for: event),
            "modifiers": Self.modifiers(from: event.modifierFlags),
        ]
        if Self.mouseTypesWithClickCount.contains(event.type) {
            params["clickCount"] = event.clickCount
        }
        if event.type == .scrollWheel {
            params["deltaX"] = event.scrollingDeltaX
            params["deltaY"] = event.scrollingDeltaY
        }
        try? await client.send(method: "Input.dispatchMouseEvent",
                               params: params, sessionId: sessionId)
    }

    /// Send a key event. Caller tags `type` as `.keyDown` / `.keyUp`
    /// since `NSEvent.type` maps to both depending on the originating
    /// responder method.
    func dispatchKey(event: NSEvent, type: KeyType) async {
        guard let chars = event.charactersIgnoringModifiers else { return }
        let params: [String: Any] = [
            "type": type.rawValue,
            "modifiers": Self.modifiers(from: event.modifierFlags),
            "text": type == .keyDown ? (event.characters ?? "") : "",
            "unmodifiedText": type == .keyDown ? chars : "",
            "key": Self.cdpKeyName(for: event),
            "code": Self.cdpCode(for: event),
            "windowsVirtualKeyCode": Int(event.keyCode),
            "nativeVirtualKeyCode": Int(event.keyCode),
        ]
        try? await client.send(method: "Input.dispatchKeyEvent",
                               params: params, sessionId: sessionId)
    }

    // MARK: - NSEvent → CDP translators

    /// CDP modifier bitmask: Alt=1, Ctrl=2, Meta=4, Shift=8.
    nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.option)  { m |= 1 }
        if flags.contains(.control) { m |= 2 }
        if flags.contains(.command) { m |= 4 }
        if flags.contains(.shift)   { m |= 8 }
        return m
    }

    nonisolated static func cdpButton(for event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:          return "left"
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:       return "right"
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:       return "middle"
        default:                                                       return "none"
        }
    }

    nonisolated static func cdpKeyName(for event: NSEvent) -> String {
        if let named = ChromiumKeyCodeTables.keyName[event.keyCode] { return named }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty { return chars }
        return "Unidentified"
    }

    nonisolated static func cdpCode(for event: NSEvent) -> String {
        ChromiumKeyCodeTables.codeName[event.keyCode] ?? ""
    }

    private static func cdpMouseType(for ns: NSEvent.EventType) -> String? {
        switch ns {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return "mousePressed"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return "mouseReleased"
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return "mouseMoved"
        case .scrollWheel:
            return "mouseWheel"
        default:
            return nil
        }
    }

    private static let mouseTypesWithClickCount: Set<NSEvent.EventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp,   .rightMouseUp,   .otherMouseUp,
    ]
}
