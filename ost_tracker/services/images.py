"""Pillow image helpers: normalise downloaded cover art to a square, cached
JPEG at a consistent size so every card renders identically. Pure image I/O,
no network."""

from __future__ import annotations

import io
from pathlib import Path

from PIL import Image, ImageOps

from ost_tracker.config import COVER_STORE_SIZE


def save_cover_from_bytes(data: bytes, dest_path: Path, size: int = COVER_STORE_SIZE) -> Path:
    """Decode ``data``, centre-crop to a ``size``×``size`` square, and write a
    JPEG to ``dest_path``. Raises if the bytes are not a decodable image.
    """
    with Image.open(io.BytesIO(data)) as img:
        return _fit_and_save(img, dest_path, size)


def save_cover_from_file(src_path: Path, dest_path: Path, size: int = COVER_STORE_SIZE) -> Path:
    with Image.open(src_path) as img:
        return _fit_and_save(img, dest_path, size)


def _fit_and_save(img: Image.Image, dest_path: Path, size: int) -> Path:
    # Flatten transparency onto white so JPEG (no alpha) looks right.
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        background = Image.new("RGBA", img.size, (255, 255, 255, 255))
        img = Image.alpha_composite(background, img).convert("RGB")
    else:
        img = img.convert("RGB")

    fitted = ImageOps.fit(img, (size, size), Image.LANCZOS)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    fitted.save(dest_path, format="JPEG", quality=90)
    return dest_path
