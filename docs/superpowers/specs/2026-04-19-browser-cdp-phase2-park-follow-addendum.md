# Phase 2 addendum: Park-and-Follow replaces CGS adopt

Date: 2026-04-19
Status: Accepted (supersedes Phase 2 / Phase 3 of the 2026-04-19 browserCDP panel design)
Related: [#2842](https://github.com/manaflow-ai/cmux/issues/2842), `2026-04-19-browser-cdp-panel-design.md`

## Why the pivot

The original design scoped Phase 2 to "adopt" a Chromium NSWindow into a cmux panel via the private CoreGraphics Services SPI `CGSSetWindowParentWithOptions`. Recent macOS research shows this is not viable:

- macOS's SkyLight/WindowServer authorization model restricts universal window-ownership to `Dock.app`. Cross-process `CGSSetWindowParent` is a no-op or requires `SIP` partially disabled (the technique shipping tools like `yabai` document). Not distributable to normal users.
- Chromium's own design notes state plainly that on macOS, "it is forbidden to embed a window from one process into a window from another process."
- The only Apple-blessed cross-process pixel path is `ScreenCaptureKit`, which requires Screen Recording TCC consent and — since macOS 15 Sequoia — weekly re-prompts. It also loses native cursor, IME, drag-and-drop, and focus routing.

## New Phase 2 approach: Park + Follow

Keep Chromium as a real, user-visible NSWindow of its own process. cmux does not embed the pixels. Instead:

1. cmux reserves a rect inside its panel.
2. cmux tells Chromium (via CDP `Browser.setWindowBounds`) to occupy that rect in screen coordinates.
3. cmux watches its panel's NSView frame and republishes the bounds on every resize/move.
4. cmux watches Chromium's window via `AXObserver` on the Chromium PID; when the user drags it, cmux re-asserts the target rect.
5. A same-process "follower" NSWindow can optionally be attached via `-addChildWindow:ordered:` to provide an unbroken cmux-coordinated visual frame around the Chromium rect.

The user sees: an NSWindow that behaves like a cmux panel, with a real, native, fully-interactive Chromium inside it. Playwright can `connectOverCDP(url)` and drive the same Chromium that the user is interacting with.

### What this buys vs adopt/capture

| | Adopt (CGS SPI) | Capture (SCStream) | Park+Follow |
|---|---|---|---|
| Shippable on macOS 14+ | No | Yes | Yes |
| Screen Recording permission | No | Yes (weekly prompt) | No |
| Native cursor/IME/focus | Yes | No | Yes |
| Native scroll/DnD | Yes | No | Yes |
| Pixel-perfect embedding | Yes | Yes | ~Yes (same screen, coordinated bounds) |
| Multi-space behavior | Unknown | Yes | Yes, with tracking |

### Known limitations we accept

1. **Dock icon pollution.** Chromium ships with its own `LSUIElement=0` Info.plist. We cannot suppress Chromium's dock tile without bundling our own Chromium. Chromium appears in the dock while alive. Mitigation: kill Chromium when the last cmux BrowserCDP panel closes; tolerate the second tile while active.
2. **Z-order flashes.** When cmux becomes key, we raise Chromium via `NSRunningApplication.activate` or Accessibility `kAXRaiseAction`. A single-frame flash is possible.
3. **Space transitions.** On `NSWorkspace.activeSpaceDidChangeNotification`, re-call `setWindowBounds` to keep Chromium on the same space as cmux.
4. **Resize tearing.** `Browser.setWindowBounds` is async over WebSocket. Debounce live-resize; accept ~1 frame of lag during drag-resize.

### When SCStream still wins

`SCStream` fallback remains the right answer for: rendering Chromium inside a preview tile on a secondary panel, compositing into an export/screenshot, or displaying Chromium on a Space where the panel itself is not active. Keep the SCStream task in the long-range plan; it is not required for a usable Phase 2.

## Phase 2 deliverable set (revised)

1. A minimal CDP WebSocket client in Swift: `ChromiumCDPClient` — JSON-RPC 2.0 over `URLSessionWebSocketTask`, supports request/response and unsolicited events.
2. `Browser.setWindowBounds` wiring: sent from cmux panel whenever its NSView's frame-on-screen changes.
3. A new `BrowserCDPPanel` + `BrowserCDPPanelView` panel type (Debug-only at first) that composes `ChromiumLaunchManager` + `ChromiumCDPClient` and drives the park rect.
4. `AXObserver` integration that re-asserts target bounds on user drag/resize.
5. Space-change tracking.
6. Kill Chromium when the last BrowserCDP panel closes.

Out of scope for Phase 2 (separate plans):
- Follower child-NSWindow for visual-only containment (polish).
- SCStream fallback for occluded / cross-space rendering.
- `browser.cdp.*` socket commands and `cmux browser cdp-url` CLI.
- Session persistence for BrowserCDP panel (tab restore across app launches).
- Per-surface Chromium user-data-dir isolation (it's already scoped per `ChromiumLaunchManager`).

## Risk register updates

| Risk | Mitigation |
|---|---|
| Chromium launched with `--remote-debugging-port` exposes a local CDP port — a malicious local process could connect | Bind to 127.0.0.1 only (already the default); document in the user-facing doc. Prefer `--remote-debugging-pipe` in a later iteration — Playwright supports it. |
| `Browser.setWindowBounds` latency during drag | Coalesce via DispatchWorkItem with 16ms (60fps) debounce; let Chromium catch up between frames. |
| AXObserver requires Accessibility permission | If missing: fall back to poll-every-250ms via `CGWindowListCopyWindowInfo`, surface a permission banner. |
| User moves Chromium off-screen | AXObserver reasserts bounds from cmux's panel rect; user cannot "escape" the park. |
| Chromium crashes / quits | LaunchManager already cleans up; panel shows a reload button that re-launches. |

## Success criteria

- Open a BrowserCDP panel in Debug build. Chromium launches. Its window is visually flush with the panel rect.
- Resize the cmux panel; Chromium follows within 1–2 frames.
- Move cmux to another Space; Chromium follows.
- Drag Chromium's title bar; it snaps back to the panel rect.
- `playwright.chromium.connectOverCDP(url)` from a Node process connects and can `page.goto`. Tests observe the same Chromium the user sees.
- Closing the panel kills the Chromium subprocess and removes its dock tile.
