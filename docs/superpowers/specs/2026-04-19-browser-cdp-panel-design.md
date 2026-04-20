# Chromium CDP panel for cmux (headful Playwright inside cmux)

Date: 2026-04-19
Status: Draft
Related issue: [#2842 Expose CDP for cmux browser surfaces](https://github.com/manaflow-ai/cmux/issues/2842)

## Goal

Let a user run Playwright headful tests whose browser is visible inside a cmux panel, and attach external CDP tooling (DevTools, Playwright `connectOverCDP`, recorders) to the same surface.

cmux's existing browser panel is WKWebView; it has no CDP and cannot be made to. `Sources/TerminalController.swift:10683+` already returns `not_supported` for every CDP-equivalent `browser.*` v2 call for that reason. We do not alter the WKWebView panel. We add a second, parallel panel type.

## Non-goals

- Replace the existing WKWebView browser panel.
- Ship Chromium inside the cmux bundle. Chromium is located at runtime (Playwright cache or `CMUX_CHROMIUM_PATH`).
- Support Linux/Windows. macOS only.
- Firefox / WebKit engines.

## Architecture

```
                 ┌──────────────────────────────────────────┐
                 │   cmux (Debug.app, NSWindow panel host)  │
                 │                                          │
                 │   BrowserCDPPanel / BrowserCDPPanelView  │
                 │       ├── ChromiumLaunchManager          │
                 │       ├── ChromiumWindowAdopter  ──┐     │
                 │       └── ChromiumScreenCapture ◄──┤     │
                 │                                     │    │
                 └─────────────────────────────────────┼────┘
                                                       │
                         spawn()  +  --remote-debugging-port=0
                                                       ▼
                       ┌───────────────────────────────────┐
                       │ Chromium.app  (Playwright bundle) │
                       │   DevTools endpoint: ws://:<port> │
                       └───────────────────────────────────┘
                                     ▲
                                     │ connectOverCDP(url)
                                     │
                              Playwright test process
                                (npx playwright test)
```

### Units

1. **ChromiumLaunchManager** — single-surface lifecycle: spawn, port discovery, log capture, stop.
2. **ChromiumWindowAdopter** — cross-process window reparent (primary display strategy).
3. **ChromiumScreenCaptureRenderer** — `ScreenCaptureKit` fallback display + CDP-routed input.
4. **BrowserCDPPanel / BrowserCDPPanelView** — SwiftUI panel + NSViewRepresentable host. One instance per surface. Owns exactly one of (2) or (3).
5. **TerminalController v2 dispatch additions** — `browser.cdp.launch`, `browser.cdp.url`, `browser.cdp.close`.
6. **CLI addition** — `cmux browser cdp-url [--surface <id>]`.

Each unit has a single clear responsibility; display strategy is swappable via a protocol (`ChromiumDisplayStrategy`).

## Component detail

### ChromiumLaunchManager

Inputs: `chromiumBinary: URL`, `initialURL: URL?`, `userDataDir: URL` (freshly created under `NSTemporaryDirectory()`).

Flags passed to Chromium:
```
--remote-debugging-port=0
--user-data-dir=<tmp>
--no-first-run --no-default-browser-check
--enable-features=NetworkService,NetworkServiceInProcess
--remote-allow-origins=*
--disable-features=GlobalMediaControls,MediaRouter
--window-size=<initial>
(initialURL if any)
```

Port discovery: `--remote-debugging-port=0` writes `<user-data-dir>/DevToolsActivePort`. The file has two lines: the port, and the `/devtools/browser/<id>` path. The manager tails it with `DispatchSource.makeFileSystemObjectSource` until both lines exist, then constructs `ws://127.0.0.1:<port><path>` and publishes it.

Chromium binary location, in order:
1. `CMUX_CHROMIUM_PATH` env var.
2. `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium` (highest numeric suffix).
3. `~/Library/Caches/ms-playwright/chromium_headless_shell-*/...` **skipped** — headless-only, not suitable.
4. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
5. `/Applications/Chromium.app/Contents/MacOS/Chromium`.

On failure, error message points to `npx playwright install chromium`.

Lifecycle: `Process` with dedicated `stdout`/`stderr` pipes (logged to `/tmp/cmux-chromium-<surface>.log`). On terminate, remove `userDataDir`.

### ChromiumWindowAdopter (primary)

Goal: visually place Chromium's native NSWindow inside cmux's panel NSView, moving/resizing with the panel.

Mechanism:
- Poll `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` filtered by `kCGWindowOwnerPID == chromium.pid` until a visible window appears.
- Use CoreGraphics Services SPI (wrapped in `CGSPrivate.h` shim inside the project) to:
  - Call `CGSSetWindowParentWithOptions(cid, chromiumWid, cmuxWid, 0x80)` to reparent.
  - Track panel frame changes via `NSView.frame` KVO; translate to Chromium window frame with `CGSMoveWindow` / `SetWindowBounds`.
- First-responder and input routing happen in Chromium naturally — the window is the real thing.

Failure modes (fall back to capture):
- SPI stubbed out by future macOS version (symbol missing → early detect at startup via `dlsym`).
- User has disabled Accessibility assistive control for cmux and adopt path asks for it.
- Chromium window never appears (10 s timeout).

### ChromiumScreenCaptureRenderer (fallback)

- `SCStream` with `SCContentFilter(desktopIndependentWindow: chromiumWindow)` at 60 fps.
- Render into `MTKView` inside the panel.
- Input bridge: intercept `NSEvent` on the capture view; translate to CDP `Input.dispatchMouseEvent` / `dispatchKeyEvent` / `insertText` via the single `ws://127.0.0.1:<port>/devtools/browser/<id>` connection. One WebSocket is shared with the LaunchManager.
- IME: route `NSTextInputClient` through `Input.insertText`. Known limitation: CJK candidate window positioning is approximate.

### BrowserCDPPanel wiring

- Add `case browserCDP` to `CmuxSurfaceType` (Sources/CmuxConfig.swift-ish layer) and parallel `Panel` subtype.
- `TabManager` grows `browserCDPPanel(for:)` accessor.
- `SessionPersistence` stores: `chromiumBinaryPathOverride`, `initialURL`, `displayStrategy` ("adopt"/"capture"/"auto").
- Command palette entry "New Chromium (CDP)" only in Debug builds initially.
- Localized strings added to `Resources/Localizable.xcstrings`.

### Socket API

Added to the v2 browser dispatch:

```
browser.cdp.launch   { surface_id?, url?, chromium_path?, strategy? }
                     → { surface_id, cdp_url, pid, strategy_used }

browser.cdp.url      { surface_id }
                     → { cdp_url }

browser.cdp.close    { surface_id } → { ok: true }
```

Threading: follow cmux's socket command policy. `launch`/`close` run off-main; they only `DispatchQueue.main.async` the minimal UI state flip. `url` is a pure read of a stored value → off-main.

### CLI

```
cmux browser cdp-url [--surface <id>]
cmux browser cdp-launch [--url <url>] [--chromium <path>] [--strategy adopt|capture|auto]
```

`cdp-url` prints the URL to stdout so it composes with `connectOverCDP`:

```ts
import { chromium } from "@playwright/test";
const url = (await Bun.$`cmux browser cdp-url`.text()).trim();
const browser = await chromium.connectOverCDP(url);
const page = (await browser.contexts())[0].pages()[0];
await page.goto("https://example.com");
```

## Display strategy selection

`strategy: "auto"` (default):
1. Probe for CGS SPI symbols at startup; cache result.
2. Probe for Screen Recording permission (`CGPreflightScreenCaptureAccess()` without triggering the prompt).
3. If SPI is available → try adopt first. If the adopt window move fails twice consecutively, tear down and fall back to capture for the lifetime of that surface.
4. If SPI missing but screen recording granted → capture.
5. If neither → user-visible error with remediation ("Enable Screen Recording for cmux in System Settings").

## Testing

Per project policy (CLAUDE.md "Test quality policy"), behavioral tests only.

1. **Socket test** in `tests_v2/browser_cdp_spec.py`:
   - Use the tagged debug socket (`CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock`).
   - `browser.cdp.launch` with `url=about:blank`.
   - Assert `cdp_url` parses as `ws://127.0.0.1:...`.
   - Shell out to a Node helper (`tests_v2/helpers/connect_cdp.mjs`) that runs `chromium.connectOverCDP(url)`, navigates to `data:text/html,<h1>cmux</h1>`, reads the title, exits 0.
   - `browser.cdp.close` returns ok.

2. **Regression discipline** (CLAUDE.md two-commit rule): for any fix on top of this, Commit 1 = failing test, Commit 2 = fix.

3. **No** AST/source-string tests.

4. **Local runs prohibited** per policy — all runs via `gh workflow run test-e2e.yml`.

## Risk register

| Risk | Mitigation |
|---|---|
| `CGSSetWindowParentWithOptions` breaks on macOS 27+ | `auto` strategy auto-falls back to SCStream capture. |
| Chromium bundle missing on user machine | Clear error message: `npx playwright install chromium`. |
| `user-data-dir` collision between parallel surfaces | Unique tmp dir per surface; cleanup on panel close + on app launch. |
| Playwright Chromium updated in cache; stale pinning | Always pick highest-suffix install at launch, not at first cmux start. |
| Screen Recording permission prompt mid-session (capture path) | Probe at panel create; surface a clear inline permission banner, don't silently fail. |
| Zombie Chromium after cmux crash | `ChromiumLaunchManager` writes `<userDataDir>/owner.plist` with parent PID; startup sweep kills PIDs whose parents are dead. |
| Focus stealing (policy: socket focus policy) | `cdp.launch` does not activate cmux or the Chromium app; focus only on explicit click in panel. |

## Rollout plan

1. Phase 1 (merge behind `#if DEBUG` Debug menu only):
   - ChromiumLaunchManager + ChromiumWindowAdopter (adopt path).
   - No CLI. Debug menu entry "New Chromium (CDP) panel" prints `cdp_url` to debug log.
2. Phase 2:
   - Socket API + CLI.
   - Playwright doc.
   - e2e socket test.
3. Phase 3:
   - Capture fallback.
   - `auto` strategy.
4. Phase 4 (follow-up, out of this spec):
   - Persist panel type in session snapshots for restore.
   - Surface Chromium download if missing, via UI button.

## Open questions

None blocking; the Chromium-location question was resolved: rely on Playwright's cache, allow override via env/flag, no bundling.
