"""Dominant-colour extraction for per-card accents.

Given a cached cover image, pick the colour that best represents it and clamp
it into a range that stays legible as a glow on the near-black app background.
Pure Pillow + math — no Qt — so it is trivially unit-testable and safe to call
from any thread.

Extraction is histogram-based: the image is shrunk and adaptively quantised to
a small palette, then each palette entry is scored by ``pixel share ×
colourfulness`` so a vivid subject beats a large murky background. Covers that
are nearly black/white/grey produce no usable accent; callers fall back to
the fixed accent token, which is the deliberate behaviour for such art.
"""

from __future__ import annotations

import colorsys
from pathlib import Path
from typing import Optional

from PIL import Image

# Quantisation shape: small enough to be fast on every cover write, large
# enough that a two-tone cover keeps its subject and background separate.
_SAMPLE_SIZE = 64
_PALETTE_COLORS = 8

# A candidate below these is "not a colour" (near-grey or near-black shadow)
# and never wins; a cover with only such candidates yields no accent at all.
_CANDIDATE_MIN_SATURATION = 0.18
_CANDIDATE_MIN_VALUE = 0.12

# Output clamps: the accent must glow against BG (#121212) without searing.
_MIN_SATURATION = 0.35
_MAX_SATURATION = 0.90
_MIN_VALUE = 0.55
_MAX_VALUE = 0.92


def _hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    h = hex_color.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _rgb_to_hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def _rgb_to_hsv(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    r, g, b = (c / 255.0 for c in rgb)
    return colorsys.rgb_to_hsv(r, g, b)


def _hsv_to_rgb(hsv: tuple[float, float, float]) -> tuple[int, int, int]:
    r, g, b = colorsys.hsv_to_rgb(*hsv)
    return round(r * 255), round(g * 255), round(b * 255)


def _dominant_color(img: Image.Image) -> Optional[tuple[int, int, int]]:
    small = img.convert("RGB")
    small.thumbnail((_SAMPLE_SIZE, _SAMPLE_SIZE))
    paletted = small.quantize(colors=_PALETTE_COLORS)
    palette = paletted.getpalette()
    counts = paletted.getcolors(maxcolors=_PALETTE_COLORS * 2) or []

    best: Optional[tuple[int, int, int]] = None
    best_score = 0.0
    total = sum(count for count, _ in counts) or 1
    for count, index in counts:
        rgb = tuple(palette[index * 3 : index * 3 + 3])
        _, s, v = _rgb_to_hsv(rgb)
        if s < _CANDIDATE_MIN_SATURATION or v < _CANDIDATE_MIN_VALUE:
            continue
        # Pixel share weighted by colourfulness: a vivid subject can outscore a
        # larger murky background, but never a same-vividness majority.
        score = (count / total) * (0.25 + s * v)
        if score > best_score:
            best_score = score
            best = rgb
    return best


def _clamp_to_legible(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    h, s, v = _rgb_to_hsv(rgb)
    s = min(max(s, _MIN_SATURATION), _MAX_SATURATION)
    v = min(max(v, _MIN_VALUE), _MAX_VALUE)
    return _hsv_to_rgb((h, s, v))


def extract_accent(image_path: Path | str) -> Optional[str]:
    """Return a clamped ``#rrggbb`` accent for the image, or None when the
    cover has no usable colour (grey/black art, missing or unreadable file) —
    the caller then falls back to the fixed accent token."""
    try:
        with Image.open(image_path) as img:
            dominant = _dominant_color(img)
    except (OSError, ValueError):
        return None
    if dominant is None:
        return None
    return _rgb_to_hex(_clamp_to_legible(dominant))
