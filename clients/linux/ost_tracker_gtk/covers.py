"""Cover loading from the local cover_image_path (GdkPixbuf, off the UI thread
happens naturally since pages load them before building rows)."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402


def load(path: Optional[str], size: int = 300) -> Optional[GdkPixbuf.Pixbuf]:
    if not path or not Path(path).is_file():
        return None
    try:
        return GdkPixbuf.Pixbuf.new_from_file_at_scale(path, size, size, True)
    except GLib.Error:
        return None
