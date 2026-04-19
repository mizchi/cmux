# Playwright headful against cmux's Chromium

> Phase 2b status: cmux can open a native panel (`BrowserCDPPanel`) that
> launches its own Chromium subprocess and drives its screen rect via CDP
> `Browser.setWindowBounds`. Chromium is still a real NSWindow in its own
> process — cmux does not embed pixels — but bounds follow the panel
> live on resize / move. Phase 3 adds a socket + CLI surface and the
> reverse sync (AXObserver) that snaps Chromium back when the user drags
> its title bar.

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

## Connect from Playwright

```ts
import { chromium } from "@playwright/test";

const cdp = process.env.CMUX_CDP_URL!; // paste from clipboard into env
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = context.pages()[0] ?? (await context.newPage());
await page.goto("https://example.com");
console.log(await page.title());
await browser.close();
```

The same `connectOverCDP(url)` call works against a `BrowserCDPPanel`'s
Chromium once you have the URL — for now the panel shows a "Copy CDP URL"
button in its placeholder view.

## Chromium binary resolution

`ChromiumBinaryLocator` searches in this order:

1. `$CMUX_CHROMIUM_PATH`
2. Highest revision under
   `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`
3. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
4. `/Applications/Chromium.app/Contents/MacOS/Chromium`

`chromium_headless_shell-*` builds are skipped — they have no window and
can't be driven via CDP for headful tests.

## Known limitations

- Chromium opens a dock tile of its own. We do not (and cannot, without
  bundling our own Chromium) suppress it.
- A user-driven drag of the Chromium title bar is not yet snapped back
  to the panel rect — Phase 3 adds the `AXObserver` loop for that.
- Session persistence does not yet restore `BrowserCDPPanel` across app
  restarts.
- There is no socket / CLI surface yet. `cmux browser cdp-url` and
  `browser.cdp.*` socket commands are Phase 3.
