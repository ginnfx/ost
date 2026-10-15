"""Boot a packaged sidecar against throwaway data before installing the app."""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def main() -> int:
    script = Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="ost-sidecar-check-") as data_home:
        environment = os.environ.copy()
        environment["OST_TRACKER_HOME"] = data_home
        environment["OST_API_WATCHDOG"] = "0"
        for name in ("OST_LAN_ENABLED", "OST_API_PORT", "OST_API_TOKEN", "OST_WRITABLE_SITE"):
            environment.pop(name, None)

        with tempfile.TemporaryFile(mode="w+t") as error_log:
            process = subprocess.Popen(
                [sys.executable, str(script)],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=error_log,
                text=True,
            )
            try:
                assert process.stdout is not None
                deadline = time.monotonic() + 20
                pending = b""
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([process.stdout], [], [], max(0, min(0.25, deadline - time.monotonic())))
                    if not ready:
                        continue
                    chunk = os.read(process.stdout.fileno(), 4096)
                    if not chunk:
                        break
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        if not line.startswith(b"OSTTRACKER_READY "):
                            continue
                        fields = dict(field.split("=", 1) for field in line.decode().split()[1:])
                        port = int(fields["port"])
                        token = fields["token"]
                        request = urllib.request.Request(
                            f"http://127.0.0.1:{port}/health",
                            headers={"X-OST-Token": token},
                        )
                        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        health_deadline = time.monotonic() + 3
                        while time.monotonic() < health_deadline:
                            try:
                                with opener.open(request, timeout=1) as response:
                                    if response.status == 200 and json.load(response) == {"status": "ok"}:
                                        print("bundled sidecar started and passed /health")
                                        return 0
                            except urllib.error.URLError:
                                time.sleep(0.1)
                        raise RuntimeError("sidecar handshake succeeded but /health failed")

                error_log.seek(0)
                details = error_log.read()[-4000:]
                raise RuntimeError(f"sidecar exited before its handshake or timed out\n{details}")
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, RuntimeError, ValueError) as error:
        print(f"sidecar check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
