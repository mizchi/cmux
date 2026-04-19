import Foundation
import AppKit

/// Translates cmux NSEvents into CDP Input.* messages so the capture
/// view can be interactive without the Chromium window being in focus.
///
/// Phase 3b scope: mouse press/release/move/wheel + basic key down/up.
/// Out of scope for this iteration: IME (NSTextInputClient), drag-and-drop,
/// touch events. The park path remains the primary interaction surface;
/// this router is only active when the panel is in capture mode.
@MainActor
final class ChromiumCDPInputRouter {
    private let client: ChromiumCDPClient

    init(client: ChromiumCDPClient) {
        self.client = client
    }

    /// Dispatch a mouse event. `location` is the cursor position inside
    /// the captured window's content area, in top-origin pixel coords
    /// (CDP expects the top-origin convention).
    func dispatchMouse(event: NSEvent, atWindowPoint location: CGPoint) async {
        let type: String
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            type = "mousePressed"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            type = "mouseReleased"
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            type = "mouseMoved"
        case .scrollWheel:
            type = "mouseWheel"
        default:
            return
        }
        let button = Self.cdpButton(for: event)
        var params: [String: Any] = [
            "type": type,
            "x": Int(location.x),
            "y": Int(location.y),
            "button": button,
            "modifiers": Self.modifiers(from: event.modifierFlags),
        ]
        if event.type == .leftMouseDown || event.type == .rightMouseDown ||
           event.type == .otherMouseDown || event.type == .leftMouseUp ||
           event.type == .rightMouseUp || event.type == .otherMouseUp {
            params["clickCount"] = event.clickCount
        }
        if event.type == .scrollWheel {
            params["deltaX"] = event.scrollingDeltaX
            params["deltaY"] = event.scrollingDeltaY
        }
        try? await client.send(method: "Input.dispatchMouseEvent", params: params)
    }

    /// Dispatch a key event. Caller is responsible for recording whether
    /// the event originated from a keyDown (→ "keyDown") or keyUp (→
    /// "keyUp"). `text` is the typed characters (nil for modifier-only).
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
        try? await client.send(method: "Input.dispatchKeyEvent", params: params)
    }

    enum KeyType: String {
        case keyDown
        case keyUp
    }

    // MARK: - CDP translation

    /// CDP modifier bit mask: Alt=1, Ctrl=2, Meta=4, Shift=8.
    nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.option) { m |= 1 }
        if flags.contains(.control) { m |= 2 }
        if flags.contains(.command) { m |= 4 }
        if flags.contains(.shift) { m |= 8 }
        return m
    }

    nonisolated static func cdpButton(for event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return "left"
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return "right"
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return "middle"
        default:
            return "none"
        }
    }

    /// Map macOS virtual key code to CDP `key` name where known.
    /// Falls back to the event's `characters`, and finally "Unidentified".
    nonisolated static func cdpKeyName(for event: NSEvent) -> String {
        if let named = keyNameTable[event.keyCode] {
            return named
        }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars
        }
        return "Unidentified"
    }

    /// Map macOS virtual key code to CDP `code` (physical key).
    nonisolated static func cdpCode(for event: NSEvent) -> String {
        codeTable[event.keyCode] ?? ""
    }

    // macOS → CDP key-name table for the common navigation / editing keys.
    // Chromium is lenient about unknown `key` values so we only need to
    // cover keys that have special meaning (modifiers, arrows, Escape,
    // Enter, Tab, Backspace, function keys). Alphanumerics fall through
    // to the characters path which is already correct for those.
    private static let keyNameTable: [UInt16: String] = [
        0x24: "Enter",
        0x4C: "Enter",           // keypad
        0x30: "Tab",
        0x33: "Backspace",
        0x35: "Escape",
        0x75: "Delete",
        0x73: "Home",
        0x77: "End",
        0x74: "PageUp",
        0x79: "PageDown",
        0x7B: "ArrowLeft",
        0x7C: "ArrowRight",
        0x7D: "ArrowDown",
        0x7E: "ArrowUp",
        0x31: " ",               // Space — CDP accepts the literal char
    ]

    private static let codeTable: [UInt16: String] = [
        0x00: "KeyA", 0x01: "KeyS", 0x02: "KeyD", 0x03: "KeyF",
        0x04: "KeyH", 0x05: "KeyG", 0x06: "KeyZ", 0x07: "KeyX",
        0x08: "KeyC", 0x09: "KeyV", 0x0B: "KeyB", 0x0C: "KeyQ",
        0x0D: "KeyW", 0x0E: "KeyE", 0x0F: "KeyR",
        0x10: "KeyY", 0x11: "KeyT", 0x1F: "KeyO",
        0x20: "KeyU", 0x22: "KeyI", 0x23: "KeyP",
        0x25: "KeyL", 0x26: "KeyJ", 0x28: "KeyK",
        0x2D: "KeyN", 0x2E: "KeyM",
        0x12: "Digit1", 0x13: "Digit2", 0x14: "Digit3", 0x15: "Digit4",
        0x16: "Digit6", 0x17: "Digit5", 0x19: "Digit9", 0x1A: "Digit7",
        0x1B: "Minus", 0x1C: "Digit8", 0x1D: "Digit0",
        0x24: "Enter",
        0x30: "Tab",
        0x31: "Space",
        0x33: "Backspace",
        0x35: "Escape",
        0x7B: "ArrowLeft",
        0x7C: "ArrowRight",
        0x7D: "ArrowDown",
        0x7E: "ArrowUp",
    ]
}
