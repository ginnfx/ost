#!/usr/bin/env python3
"""Tile the key screenshots into one contact sheet for the final review gate."""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

SHOTS = Path("_shots")
BG = (23, 19, 16)       # tokens.BG
INK = (242, 233, 221)   # tokens.TEXT
TILE_W = 640
COLS = 3
PAD = 20
LABEL_H = 28

TILES = [
    ("v2_leaderboard", "Leaderboard · Ranking (4-item sidebar, segmented)"),
    ("ev_leaderboard_completed", "Leaderboard · Completed segment"),
    ("ev_leaderboard_hover", "Hover glow + lift (motion)"),
    ("ev_detail", "Detail · flat stats strip, mono scores"),
    ("v2_rate", "Rate · segmented, mono cells"),
    ("v2_stats", "Stats · mono table numbers"),
    ("v2_people", "People (Roster)"),
    ("ks_all", "Kitchen sink · every widget + state"),
    ("ev_notes", "Notes (demoted to menu window)"),
]


def main() -> int:
    tiles = []
    for name, label in TILES:
        p = SHOTS / f"{name}.png"
        if not p.exists():
            print(f"[contact_sheet] skip missing {p}")
            continue
        im = Image.open(p).convert("RGB")
        scale = TILE_W / im.width
        im = im.resize((TILE_W, int(im.height * scale)))
        tiles.append((im, label))

    if not tiles:
        print("[contact_sheet] no tiles found")
        return 1

    rows = (len(tiles) + COLS - 1) // COLS
    row_h = max(im.height for im, _ in tiles) + LABEL_H
    sheet_w = COLS * TILE_W + (COLS + 1) * PAD
    sheet_h = rows * (row_h + PAD) + PAD
    sheet = Image.new("RGB", (sheet_w, sheet_h), BG)
    draw = ImageDraw.Draw(sheet)

    for i, (im, label) in enumerate(tiles):
        r, c = divmod(i, COLS)
        x = PAD + c * (TILE_W + PAD)
        y = PAD + r * (row_h + PAD)
        draw.text((x, y), label, fill=INK)
        sheet.paste(im, (x, y + LABEL_H))

    out = SHOTS / "contact_sheet.png"
    sheet.save(out)
    print(f"[contact_sheet] wrote {out} ({sheet_w}x{sheet_h}, {len(tiles)} tiles)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
