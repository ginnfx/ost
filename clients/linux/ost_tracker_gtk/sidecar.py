"""Spawn/teardown of the Python sidecar on Linux (killpg, ppid watchdog)."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class SidecarConfig:
    python_path: str
    script_path: str
    working_dir: str
    extra_env: dict = field(default_factory=dict)

    @staticmethod
    def resolve() -> "SidecarConfig":
        packaged = SidecarConfig._packaged()
        return packaged if packaged else SidecarConfig._development()

    @staticmethod
    def _packaged() -> "SidecarConfig | None":
        base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent.parent))
        python = base / "python-runtime" / "bin" / "python3.11"
        if not python.is_file():
            return None
        data_home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "ost-tracker"
        data_home.mkdir(parents=True, exist_ok=True)
        return SidecarConfig(
            python_path=str(python),
            script_path=str(base / "backend" / "api.py"),
            working_dir=str(base),
            extra_env={"OST_TRACKER_HOME": str(data_home)},
        )

    @staticmethod
    def _development() -> "SidecarConfig":
        repo = Path(os.environ.get("OST_SIDECAR_REPO") or _locate_repo())
        python = os.environ.get("OST_SIDECAR_PYTHON") or str(repo / ".venv" / "bin" / "python3")
        script = os.environ.get("OST_SIDECAR_SCRIPT") or str(repo / "backend" / "api.py")
        return SidecarConfig(python_path=python, script_path=script, working_dir=str(repo))


def _locate_repo() -> Path:
    d = Path(__file__).resolve()
    for parent in (d, *d.parents):
        if (parent / "backend" / "api.py").is_file():
            return parent
    raise FileNotFoundError("repo checkout not found; set OST_SIDECAR_REPO")


class Sidecar:
    """Owns the sidecar process. Teardown = kill(-pgid, SIGTERM) + backstop."""

    def __init__(self, config: SidecarConfig | None = None):
        self._config = config or SidecarConfig.resolve()
        self._proc: subprocess.Popen | None = None

    def start(self, timeout: float = 20.0) -> tuple[int, str]:
        env = dict(os.environ)
        env.update(self._config.extra_env)
        self._proc = subprocess.Popen(
            [self._config.python_path, self._config.script_path],
            cwd=self._config.working_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,  # own process group → killpg teardown
        )
        assert self._proc.stdout is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self._proc.stdout.readline()
            if not line:
                if self._proc.poll() is not None:
                    raise RuntimeError(f"sidecar exited before handshake (code {self._proc.returncode})")
                continue
            text = line.decode(errors="replace").strip()
            if text.startswith("OSTTRACKER_READY"):
                port, token = _parse_handshake(text)
                self.port, self.token = port, token
                return port, token
        raise TimeoutError("sidecar handshake timed out")

    port: int = 0
    token: str = ""

    def stop(self) -> None:
        if self._proc is None or self._proc.poll() is not None:
            return
        try:
            os.killpg(self._proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self._proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self._proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            self._proc.wait(timeout=2.0)
        self._proc = None


def _parse_handshake(line: str) -> tuple[int, str]:
    port, token = 0, ""
    for field in line.split():
        if field.startswith("port="):
            port = int(field[len("port="):])
        elif field.startswith("token="):
            token = field[len("token="):]
    if port == 0 or not token:
        raise ValueError(f"malformed handshake: {line}")
    return port, token
