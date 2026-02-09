#!/usr/bin/env python3
"""
pai-lite dashboard server with lazy JSON regeneration.

Usage: python3 dashboard_server.py <port> <dashboard_dir> <pai_lite_bin> [ttl]

Serves static files from dashboard_dir. When data/*.json is requested,
checks staleness and regenerates (via pai-lite dashboard generate) if
older than TTL seconds. A threading lock prevents concurrent regeneration.
"""

import sys
import os
import time
import subprocess
import threading
import http.server
import functools

DEFAULT_TTL = 5
DATA_FILES = {"slots.json", "ready.json", "notifications.json", "mayor.json"}

_regen_lock = threading.Lock()
_last_regen_time = 0.0


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, pai_lite_bin="", ttl=DEFAULT_TTL, **kwargs):
        self.pai_lite_bin = pai_lite_bin
        self.ttl = ttl
        super().__init__(*args, **kwargs)

    def do_GET(self):
        path = self.path.lstrip("/").split("?")[0]
        basename = os.path.basename(path)
        if path.startswith("data/") and basename in DATA_FILES:
            self._maybe_regenerate()
        super().do_GET()

    def _maybe_regenerate(self):
        global _last_regen_time
        now = time.time()
        if now - _last_regen_time < self.ttl:
            return
        if _regen_lock.acquire(blocking=False):
            try:
                if time.time() - _last_regen_time < self.ttl:
                    return
                subprocess.run(
                    [self.pai_lite_bin, "dashboard", "generate"],
                    timeout=30,
                    capture_output=True,
                )
                _last_regen_time = time.time()
            except Exception as e:
                print(f"Regeneration error: {e}", file=sys.stderr)
            finally:
                _regen_lock.release()

    def log_message(self, format, *args):
        # Suppress per-request logging; only errors go to stderr
        pass


def main():
    if len(sys.argv) < 4:
        print(
            "Usage: dashboard_server.py <port> <dashboard_dir> <pai_lite_bin> [ttl]",
            file=sys.stderr,
        )
        sys.exit(1)

    port = int(sys.argv[1])
    dashboard_dir = sys.argv[2]
    pai_lite_bin = sys.argv[3]
    ttl = int(sys.argv[4]) if len(sys.argv) > 4 else DEFAULT_TTL

    os.chdir(dashboard_dir)

    handler = functools.partial(DashboardHandler, pai_lite_bin=pai_lite_bin, ttl=ttl)
    server = http.server.HTTPServer(("", port), handler)
    print(f"pai-lite dashboard serving on port {port} (TTL={ttl}s)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
