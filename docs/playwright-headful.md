# Playwright headful against cmux's Chromium (phase 1)

> Phase 1 status: cmux launches Chromium and hands you its CDP URL. The
> Chromium window is separate from the cmux window. Phase 2 will embed it
> into a cmux panel.

## Launch

In a DEBUG build:

1. `Debug → Debug Windows → Launch Chromium (CDP)…`
2. An alert shows `ws://127.0.0.1:<port>/devtools/browser/<id>`. The same
   URL is on the clipboard.

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

## Chromium binary resolution

`ChromiumBinaryLocator` searches in this order:

1. `$CMUX_CHROMIUM_PATH`
2. Highest revision under `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`
3. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
4. `/Applications/Chromium.app/Contents/MacOS/Chromium`

`chromium_headless_shell-*` builds are skipped — they don't have a window
and can't be driven via CDP for headful tests.

## Known limitations (phase 1)

- The Chromium window is a separate OS window, not a cmux panel.
- Only one launch at a time (the Debug button replaces the previous one).
- No socket or CLI surface yet; use the Debug menu.

Phase 2 adds the embedded panel; phase 3 adds the `cmux browser cdp-url`
CLI and `browser.cdp.*` socket commands.
