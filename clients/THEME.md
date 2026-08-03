# Shared visual language

Both native clients mirror the macOS SwiftUI app's look. These tokens are the
single source of truth for color and geometry; the per-client files
(`clients/windows/OSTTracker/Themes/Theme.cs`, `clients/linux/ost_tracker_gtk/theme.py`)
hardcode the same values.

## Colors

| Token | Hex | Use |
|-------|-----|-----|
| bg            | `#101014` | window background |
| bgRaised      | `#18181E` | panels, toolbars |
| cardSurface   | `#1C1C24` | roster cards |
| textPrimary   | `#F5F2EA` | headings, titles |
| textDim       | `#9B97A8` | secondary text |
| accent default| `#20D760` | chrome accent (user-themable; cover accents tint cards) |
| gold          | `#F2B705` | rank badge #1 |
| pink          | `#FF3D81` | rank badge #2 |
| rust          | `#E8541E` | rank badge #3 |

Accent presets: `#20D760` emerald, `#F5A623` amber, `#FF3D81` magenta,
`#4FC3F7` ice, `#8A54D0` violet, `#FF6B4A` coral.

## Geometry

- Card corner radius: 10; panel corner radius: 12; buttons/pills: capsule.
- Roster card: square cover on top, rank badge top-left, title + submitter
  below, score bottom-right. Badge colors follow the rank metals above.

## Behavior

- Covers load from the local `cover_image_path` off the UI thread, downsampled
  to ~300px; missing/blank covers render a neutral placeholder tile.
- Each card is tinted with its OST's `cover_accent_hex` (subtle border/glow).
- Roster double-click plays; single click opens the detail view.
