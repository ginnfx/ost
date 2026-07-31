#!/usr/bin/env python3
"""Generate assets/icon.icns for the packaged .app.

Draws a rounded gradient tile with a musical note and renders it to a macOS
.icns via `iconutil`. Non-fatal: if `iconutil` isn't available the PNG is still
written and packaging proceeds without a custom icon.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ICONSET = ASSETS / "icon.iconset"


def _rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_base(size: int = 1024) -> Image.Image:
    # Vertical gradient background.
    bg = Image.new("RGB", (size, size))
    top, bottom = (76, 139, 245), (46, 52, 64)
    for y in range(size):
        t = y / size
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for_line = Image.new("RGB", (size, 1), (r, g, b))
        bg.paste(for_line, (0, y))

    draw = ImageDraw.Draw(bg)
    white = (245, 247, 250)
    # Eighth note: two note heads + stems + a beam.
    head_r = size * 0.10
    y_head = size * 0.66
    x1 = size * 0.34
    x2 = size * 0.60
    draw.ellipse([x1 - head_r, y_head - head_r * 0.8, x1 + head_r, y_head + head_r * 0.8], fill=white)
    draw.ellipse([x2 - head_r, y_head - head_r * 0.8, x2 + head_r, y_head + head_r * 0.8], fill=white)
    stem_w = size * 0.028
    draw.rectangle([x1 + head_r - stem_w, size * 0.30, x1 + head_r, y_head], fill=white)
    draw.rectangle([x2 + head_r - stem_w, size * 0.30, x2 + head_r, y_head], fill=white)
    draw.polygon(
        [(x1 + head_r - stem_w, size * 0.30), (x2 + head_r, size * 0.30),
         (x2 + head_r, size * 0.40), (x1 + head_r - stem_w, size * 0.40)],
        fill=white,
    )

    # Clip to a rounded square.
    rounded = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rounded.paste(bg, (0, 0), _rounded_mask(size, int(size * 0.22)))
    return rounded


def main() -> int:
    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)
    base = draw_base(1024)
    png_path = ASSETS / "icon.png"
    base.save(png_path)

    specs = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for px, name in specs:
        base.resize((px, px), Image.LANCZOS).save(ICONSET / name)

    icns_path = ASSETS / "icon.icns"
    try:
        subprocess.run(
            ["iconutil", "-c", "icns", str(ICONSET), "-o", str(icns_path)],
            check=True,
        )
        print(f"Wrote {icns_path}")
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        print(f"iconutil unavailable ({exc}); skipping .icns. PNG at {png_path}.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
