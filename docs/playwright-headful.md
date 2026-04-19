# Playwright headful against cmux's Chromium

> Phase 3b status: cmux opens a native panel (`BrowserCDPPanel`) that
> launches its own Chromium subprocess and drives its screen rect via
> CDP `Browser.setWindowBounds`. Two rendering modes are available:
>
> - **Park** (default): Chromium stays a real NSWindow in its own
>   process; bounds follow the panel on resize / move, user-drags snap
>   back via AXObserver, visibility tracks tab switch + window
>   miniaturize + active Space.
> - **Capture** (experimental, macOS 12.3+, requires Screen Recording
>   permission): cmux mirrors Chromium's window via ScreenCaptureKit
>   and routes mouse + key input through CDP `Input.dispatch*`. Lets
>   the panel render Chromium pixels directly for scenarios where the
>   native window is occluded or on a different Space.
>
> A v2 socket API and `cmux browser cdp-*` CLI surface the panel
> lifecycle and CDP URL so external scripts can `connectOverCDP`
> without clicking through the UI.

## Creating a panel (end-to-end)

In a DEBUG build:

1. `Debug → Debug Windows → New Chromium Panel`

The active workspace's focused pane gains a new tab titled "Chromium".
Behind the tab cmux spawns a Chromium process with
`--remote-debugging-port=0 --user-data-dir=<scoped-tmp>`, reads the
`DevToolsActivePort` file, opens a WebSocket to the resulting
`ws://127.0.0.1:<port>/devtools/browser/<id>`, and starts issuing
`Browser.setWindowBounds` against the panel's on-screen rect (16 ms
debounce, with an immediate replay once the CDP handshake finishes).

Closing the tab terminates the Chromium subprocess and removes the
scoped user-data-dir.

## One-shot Debug buttons (standalone Chromium)

Two other Debug menu buttons drive a single standalone Chromium
(separate from any panel):

- `Debug → Debug Windows → Launch Chromium (CDP)…` — spawns Chromium
  and copies its CDP URL to the clipboard.
- `Debug → Debug Windows → Move Chromium to cmux Window` — sends
  `Browser.setWindowBounds` to the standalone Chromium so it occupies
  the cmux main window's rect.
- `Debug → Debug Windows → Toggle Chromium Auto-Follow` — toggles a
  live follower on the cmux main window for the standalone Chromium
  (same debounce, same replay semantics as the panel).

## CLI surface (Phase 3)

```sh
# Open a new BrowserCDP panel in the focused pane. Prints surface/status/url.
cmux browser cdp-launch

# List all existing BrowserCDP panels (tab-separated: id status url).
cmux browser cdp-list

# Print the CDP WebSocket URL of a specific panel. Exits 1 if not yet ready.
cmux browser <surface> cdp-url

# Close a BrowserCDP panel (terminates its Chromium subprocess).
cmux browser <surface> cdp-close
```

`cdp-url` prints only the URL on stdout so it composes cleanly with
Playwright scripts:

```sh
surface=$(cmux browser cdp-launch --json | jq -r '.surface_id')
# wait briefly for Chromium handshake
until url=$(cmux browser "$surface" cdp-url 2>/dev/null); do sleep 0.1; done

node -e '(async()=>{
  const {chromium} = require("playwright");
  const b = await chromium.connectOverCDP(process.argv[1]);
  const c = b.contexts()[0] ?? (await b.newContext());
  const p = c.pages()[0] ?? (await c.newPage());
  await p.goto("https://example.com");
  console.log(await p.title());
  await b.close();
})()' "$url"
```

## Socket API (Phase 3)

The v2 socket dispatch exposes the same lifecycle under
`browser.cdp.{launch,url,list,close}`. Each returns a JSON envelope.
See `Sources/Panels/BrowserCDPLaunch/BrowserCDPSocketCommands.swift`
for the authoritative shape. Rough outline:

```
browser.cdp.launch  { tab_id?, workspace?, window? }
                    → { surface_id, cdp_url?, status }

browser.cdp.url     { surface_id }
                    → { surface_id, cdp_url?, status }

browser.cdp.list    {}
                    → { surfaces: [{ surface_id, workspace_id, cdp_url?, status }] }

browser.cdp.close   { surface_id } → { ok: true, surface_id }
```

`status` is one of `launching`, `connected`, or `exited`. `cdp_url`
is omitted when Chromium is still handshaking or after it has exited.

## Connect from Playwright

```ts
import { chromium } from "@playwright/test";

const cdp = process.env.CMUX_CDP_URL!; // or $(cmux browser <surface> cdp-url)
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = context.pages()[0] ?? (await context.newPage());
await page.goto("https://example.com");
console.log(await page.title());
await browser.close();
```

## Chromium binary resolution

`ChromiumBinaryLocator` searches in this order:

1. `$CMUX_CHROMIUM_PATH`
2. Highest revision under
   `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`
3. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
4. `/Applications/Chromium.app/Contents/MacOS/Chromium`

`chromium_headless_shell-*` builds are skipped — they have no window and
can't be driven via CDP for headful tests.

## Capture mode (experimental)

The park placeholder shows an **Enable pixel capture (experimental)**
button once the CDP client is connected. Clicking it starts an
`SCStream` against the Chromium window, renders frames into the panel,
and routes mouse / keyboard events through CDP. A **Switch back to
park mode** overlay is available in capture view.

Capture mode requires:

- macOS 12.3 (Monterey) or later.
- Screen Recording permission for cmux. On macOS 15 Sequoia the system
  re-prompts weekly.

Known gaps:

- IME composition (CJK) is not yet routed; use park mode for typing.
- Drag-and-drop between the captured area and other apps is not
  supported.
- Chromium still has its own dock tile and can be activated directly
  from the Dock; the capture view does not intercept that path.

## Known limitations

- Chromium opens a dock tile of its own. We do not (and cannot, without
  bundling our own Chromium) suppress it.
- AXObserver-based reverse sync requires Accessibility permission. If
  it's not granted the forward path (cmux → Chromium) still works but
  user-driven drags won't be re-asserted.
- `browser.cdp.launch` starts Chromium with `--remote-debugging-port=0`
  on 127.0.0.1. A localhost-only port is still reachable by any local
  process; use the `--user-data-dir`-scoped CDP URL as a session token.
  `--remote-debugging-pipe` is deferred because it's incompatible with
  Playwright's external `connectOverCDP(url)` API.
