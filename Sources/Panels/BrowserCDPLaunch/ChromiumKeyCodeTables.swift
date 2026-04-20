import Foundation

/// macOS virtual-keycode → CDP identifier tables used by
/// `ChromiumCDPInputRouter` to translate `NSEvent.keyCode` values into
/// the `key` (logical) and `code` (physical) strings that CDP's
/// `Input.dispatchKeyEvent` expects.
///
/// Chromium is lenient about unknown `key` values and ignores an empty
/// `code`, so we only have to cover the keys whose semantics differ
/// from their typed characters — navigation / editing / modifiers.
/// Alphanumerics hit the `characters` fallback in the router.
enum ChromiumKeyCodeTables {
    /// Logical key names. Driven by NSEvent.keyCode.
    static let keyName: [UInt16: String] = [
        0x24: "Enter",
        0x4C: "Enter",           // keypad return
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

    /// Physical key codes in CDP's W3C UI Events spelling.
    static let codeName: [UInt16: String] = [
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
        0x1B: "Minus",  0x1C: "Digit8", 0x1D: "Digit0",
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
