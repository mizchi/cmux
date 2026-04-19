# Playwright against cmux's headless Chromium

> Status: Phase 3c. The BrowserCDP panel launches a headless Chromium
> (`--headless=new`) and renders the page through CDP's
> `Page.startScreencast` into the panel view. No native Chromium
> window, no Screen Recording permission required. Mouse and keyboard
> events are forwarded via `Input.dispatchMouseEvent` /
> `dispatchKeyEvent`, and the rendered viewport is kept in sync with
> the panel size through `Emulation.setDeviceMetricsOverride`.

## Creating a panel

In a DEBUG build:

- `⌘⇧P → "New Tab (Chromium / CDP)"`, or
- `Debug → Debug Windows → "New Chromium Panel"`, or
- via socket:
  ```sh
  CMUX_SOCKET_PATH=/tmp/cmux-debug-browser-cdp.sock \
    cmux browser cdp-launch
  ```

The panel's top toolbar has back / forward / reload + an address bar.
Type `example.com` and press Return — the page loads inline.

## Socket + CLI surface

```
browser.cdp.launch  { tab_id?, workspace?, window? }
                    → { surface_id, cdp_url?, status }

browser.cdp.url     { surface_id }
                    → { surface_id, cdp_url?, status }

browser.cdp.list    {}
                    → { surfaces: [{ surface_id, workspace_id, cdp_url?, status }] }

browser.cdp.close   { surface_id } → { ok: true, surface_id }
```

CLI shortcuts:

```sh
cmux browser cdp-launch            # create a panel, print handle + URL
cmux browser cdp-list              # tab-separated id / status / url
cmux browser <surface> cdp-url     # print just the URL (pipe-friendly)
cmux browser <surface> cdp-close   # close the panel
```

## Connect from Playwright

Any Playwright version with `chromium.connectOverCDP(url)` will
attach to the panel's Chromium:

```ts
import { chromium } from "@playwright/test";

const cdp = process.env.CMUX_CDP_URL!; // from `cmux browser <s> cdp-url`
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = context.pages()[0] ?? (await context.newPage());
await page.goto("https://example.com");
console.log(await page.title());
await browser.close();
```

For a drop-in `@playwright/test` adapter that routes every test's
built-in `page` / `context` / `browser` fixture through the cmux
panel's Chromium, see `/tmp/cmux-playwright-demo/tests/fixtures.ts` in
the in-repo demo.

## Chromium binary resolution

`ChromiumBinaryLocator` searches in this order:

1. `$CMUX_CHROMIUM_PATH`
2. Highest revision under
   `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`
3. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
4. `/Applications/Chromium.app/Contents/MacOS/Chromium`

`chromium_headless_shell-*` builds are skipped — they don't ship a
full headless renderer suitable for screencast.

## Known limitations

- The WS transport is `NWConnection`-based (not
  `URLSessionWebSocketTask`) because Chromium 147+ silently drops
  frames when the default `permessage-deflate` extension is
  negotiated.
- IME composition (CJK) is not yet forwarded; plain keystrokes work.
- Drag-and-drop between the panel and other apps is not supported.
- Chromium subprocess is terminated when the panel closes and at
  app quit. Orphans can appear if the app crashes mid-flight; clean
  up with `pkill -f "Google Chrome.*remote-debugging-port"`.
