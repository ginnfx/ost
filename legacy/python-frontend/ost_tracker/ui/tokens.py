"""Design tokens — the ONE place raw colour hexes, font family names and the
spacing scale are allowed to appear.

Nothing else in the codebase may hardcode a hex colour or a font-family string:
every widget, painter and stylesheet reads from here (usually re-exported via
``theme``). Keeping this module free of Qt imports makes it a pure, importable,
trivially-testable home for every token.

Palette: high-contrast dark theme — near-black base, pure-white text,
emerald-green selection/focus/hover accent, gold reserved for
rank/achievement, rust-orange tertiary. Flat fills, no gradients, and
deliberately NO purple/violet/blue accents anywhere. (The accent went gold in
the 2026-07 patch and the owner called it back: green is intentional.)
"""

from __future__ import annotations

# --- typography (family names as Qt registers them) -------------------------
DISPLAY_FAMILY = "Chakra Petch"      # headers/titles — bold, uppercase
BODY_FAMILY = "IBM Plex Sans"        # body text
MONO_FAMILY = "JetBrains Mono"       # all numeric readouts

# --- accent (emerald green) --------------------------------------------------
ACCENT = "#4ade80"          # emerald green — selection/focus/hover glow
ACCENT_2 = "#4ade80"        # back-compat alias (no gradients any more)
ACCENT_HOVER = "#86efac"
ACCENT_DIM = "#22c55e"
ACCENT_SOFT = "#0d2e1a"     # green-tinted fill for subtle selections/chips
ACCENT_TERTIARY = "#e8541e"  # rust orange — tertiary accent
HOT = "#4ade80"

# --- surfaces (Spotify-inspired neutral-dark) -------------------------------
BG = "#121212"              # near-black background
SIDEBAR_BG = "#000000"
SURFACE = "#181818"         # card surface
SURFACE_RAISED = "#242424"
SURFACE_HOVER = "#2a2a2a"
BORDER = "#333333"
BORDER_DARK = "#000000"     # black — icon chips, card outlines, definition
BORDER_HOVER = "#4ade80"
BASE_INPUT = "#1a1a1a"      # QPalette.Base (text input wells)

# --- text (high-contrast white-on-black) ------------------------------------
TEXT = "#ffffff"
TEXT_DIM = "#b3b3b3"
TEXT_FAINT = "#727272"

# --- foregrounds on coloured surfaces --------------------------------------
ON_ACCENT = "#000000"       # black on accent — crisp Spotify-style buttons
INK = "#121212"             # near-black ink on gold/medal surfaces

# --- score heat ramp --------------------------------------------------------
SCORE_HIGH = "#6fcf97"
SCORE_MID = "#f2b705"
SCORE_LOW = "#e8541e"

# --- ranks ------------------------------------------------------------------
GOLD = "#f2b705"            # rank 1 / achievement
SILVER = "#c9c2b5"          # rank 2
BRONZE = "#c97c3d"          # rank 3

# --- self-rating / danger / incomplete -------------------------------------
SELF_TINT = "#1a1a10"       # gold-tinted fill behind a submitter's own 10/10
DANGER = "#e8541e"
DANGER_TEXT = "#f08a63"
DANGER_BORDER = "#6a3a2b"
DANGER_HOVER_BG = "#2a1818"
INCOMPLETE_TINT = "#1f1313"

# --- inline rating strip placeholder (TEMPORARY) -----------------------------
# The detail view's embedded rating strip pins its green independently of the
# accent tokens, as explicit placeholder styling until the owner finalises its
# look (follow-up patch). Nothing else may use these.
RATE_STRIP_GREEN = "#4ade80"
RATE_STRIP_GREEN_SOFT = "#0d2e1a"

# --- completion heatmap: "missing" cells -----------------------------------
MISSING_FILL = "#6a2f2f"
MISSING_BORDER = "#7d3a3a"
MISSING_TEXT = "#a24a4a"

# --- deterministic cover placeholders (neutral dark; no blue > red) ---------
PLACEHOLDER_GRADIENTS = [
    ("#2a2a2a", "#181818"),  # neutral grey
    ("#1e2e22", "#121a15"),  # dark forest
    ("#2a2818", "#1a1a10"),  # dark olive
    ("#222222", "#161616"),  # charcoal
    ("#262020", "#181414"),  # dark wine
    ("#2a2420", "#1a1614"),  # dark clay
]

# --- layout metrics (px) ----------------------------------------------------
PAGE_MARGIN = 24
PAGE_MARGIN_BOTTOM = 16
HEADER_GAP = 16
ROW_GAP = 12
CARD_GAP = 18
