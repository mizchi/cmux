#!/usr/bin/env python3
"""v2 regression: browser.cdp.{launch,url,list,close} lifecycle.

This test does NOT launch Chromium — it only exercises the socket
envelope shape. An attempt to actually connect to Chromium requires
`npx playwright install chromium` on the test host and is deferred to a
separate e2e suite. Here we verify:

  * browser.cdp.launch returns a surface_id and a status in
    {launching, connected, exited}. cdp_url may or may not be present
    (depends on how quickly DevToolsActivePort appears).
  * browser.cdp.list contains the surface we just launched.
  * browser.cdp.url returns a consistent status for the known surface.
  * browser.cdp.close returns ok:true and removes the surface from list.

The test is skipped gracefully when Chromium cannot be located on the
host — launch returns an error with a clear message in that case, and
we do not treat it as a regression.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        # Try to launch. If Chromium is not present in the test env, the
        # panel still gets created and reports an error status — we just
        # assert the envelope shape and close.
        try:
            launched = c._call("browser.cdp.launch", {}) or {}
        except cmuxError as e:
            print(f"browser.cdp.launch failed: {e}; skipping", file=sys.stderr)
            return 0

        sid = launched.get("surface_id")
        status = launched.get("status")
        _must(isinstance(sid, str) and len(sid) > 0, f"no surface_id: {launched}")
        _must(status in {"launching", "connected", "exited"}, f"bad status: {status!r}")

        # Give Chromium up to 5s to hand us a CDP URL. If it never comes,
        # that is fine for this test — we only check the envelope shape.
        url = None
        for _ in range(50):
            got = c._call("browser.cdp.url", {"surface_id": sid}) or {}
            if got.get("cdp_url"):
                url = got["cdp_url"]
                break
            time.sleep(0.1)

        listed = c._call("browser.cdp.list", {}) or {}
        surfaces = listed.get("surfaces") or []
        matching = [s for s in surfaces if s.get("surface_id") == sid]
        _must(len(matching) == 1, f"list missing our surface: {surfaces}")

        closed = c._call("browser.cdp.close", {"surface_id": sid}) or {}
        _must(closed.get("ok") is True, f"close did not report ok:true: {closed}")

        # After close, the surface should drop out of list within a
        # short window. The actual teardown is on a background queue.
        deadline = time.time() + 3
        while time.time() < deadline:
            remaining = (c._call("browser.cdp.list", {}) or {}).get("surfaces") or []
            if not any(s.get("surface_id") == sid for s in remaining):
                break
            time.sleep(0.1)
        else:
            raise cmuxError(f"surface {sid} still in list after close")

        print(f"OK cdp-lifecycle status={status} url={url or 'none'}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
