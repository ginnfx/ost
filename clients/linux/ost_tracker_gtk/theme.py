"""Theme tokens + GTK CSS, mirroring the macOS app (see clients/THEME.md)."""

from __future__ import annotations

import json
import os
from pathlib import Path

ACCENT_DEFAULT = "#20D760"
PRESETS = ["#20D760", "#F5A623", "#FF3D81", "#4FC3F7", "#8A54D0", "#FF6B4A"]
GOLD = "#F2B705"
PINK = "#FF3D81"
RUST = "#E8541E"
BG = "#101014"
BG_RAISED = "#18181E"
CARD = "#1C1C24"
TEXT = "#F5F2EA"
TEXT_DIM = "#9B97A8"


def css() -> str:
    return f"""
window {{
  background-color: {BG};
  color: {TEXT};
}}
.headerbar, .titlebar {{
  background-color: {BG_RAISED};
  color: {TEXT};
}}
.card {{
  background-color: {CARD};
  border-radius: 10px;
  border: 1px solid alpha(white, 0.12);
}}
.dim-label {{ color: {TEXT_DIM}; }}
.rank-badge {{
  border-radius: 12px;
  padding: 1px 8px;
  font-weight: bold;
}}
.rank-1 {{ background-color: {GOLD}; color: #101014; }}
.rank-2 {{ background-color: {PINK}; color: #101014; }}
.rank-3 {{ background-color: {RUST}; color: #101014; }}
.rank-other {{ background-color: alpha(white, 0.14); color: {TEXT}; }}
.accent {{ color: {ACCENT_DEFAULT}; }}
"""


def apply() -> None:
    import gi

    gi.require_version("Gtk", "4.0")
    from gi.repository import Gdk, Gtk

    provider = Gtk.CssProvider()
    provider.load_from_string(css())
    display = Gdk.Display.get_default()
    if display is not None:
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )


def _config_path() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "ost-tracker" / "theme.json"


def accent() -> str:
    """The chosen chrome accent, persisted per user (mirrors macOS UserDefaults)."""
    try:
        return str(json.loads(_config_path().read_text()).get("accent", ACCENT_DEFAULT))
    except (OSError, ValueError):
        return ACCENT_DEFAULT


def set_accent(hex_value: str) -> None:
    _config_path().parent.mkdir(parents=True, exist_ok=True)
    _config_path().write_text(json.dumps({"accent": hex_value}))
